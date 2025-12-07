defmodule Doctrans.Processing.LlmProcessor do
  @moduledoc """
  Handles LLM-based processing of document pages.

  Performs markdown extraction and translation using Ollama models.
  """

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Documents
  alias Doctrans.Search.EmbeddingWorker

  @max_retries 3

  # Allow Ollama module to be configured for testing
  defp ollama_module do
    Application.get_env(:doctrans, :ollama_module, Doctrans.Processing.Ollama)
  end

  @doc """
  Processes all pages of a document through the LLM pipeline.

  Returns `:ok`, `{:cancelled, document_id}`, or `{:error, reason}`.
  """
  def process_document(document_id, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping LLM processing")
      :ok
    else
      document_id
      |> process_all_pages(cancelled_documents)
      |> handle_result(document_id)
    end
  end

  defp handle_result(:ok, document_id) do
    document = Documents.get_document!(document_id)
    Documents.update_document_status(document, "completed")
    Documents.broadcast_document_update(document)
    :ok
  end

  defp handle_result({:cancelled, _}, document_id) do
    Logger.info("Document #{document_id} LLM processing was cancelled")
    :ok
  end

  defp handle_result({:error, reason}, document_id) do
    Logger.error("Failed to process LLM for document #{document_id}: #{reason}")
    maybe_update_document_error(document_id, reason)
    {:error, reason}
  end

  defp maybe_update_document_error(document_id, reason) do
    case Documents.get_document(document_id) do
      nil -> :ok
      document -> Documents.update_document_status(document, "error", reason)
    end
  end

  defp process_all_pages(document_id, cancelled_documents) do
    process_next_page(document_id, cancelled_documents)
  end

  defp process_next_page(document_id, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      {:cancelled, document_id}
    else
      find_and_process_next_page(document_id, cancelled_documents)
    end
  end

  defp find_and_process_next_page(document_id, cancelled_documents) do
    case Documents.get_next_page_for_extraction(document_id) do
      nil -> find_translation_page(document_id, cancelled_documents)
      page -> process_page_and_continue(page, document_id, cancelled_documents)
    end
  end

  defp find_translation_page(document_id, cancelled_documents) do
    if Documents.all_pages_completed?(document_id) do
      :ok
    else
      case Documents.get_next_page_for_translation(document_id) do
        nil -> :ok
        page -> process_page_and_continue(page, document_id, cancelled_documents)
      end
    end
  end

  defp process_page_and_continue(page, document_id, cancelled_documents) do
    case maybe_extract_page(page) do
      {:error, reason} ->
        {:error, reason}

      updated_page ->
        maybe_translate_and_continue(updated_page, document_id, cancelled_documents)
    end
  end

  defp maybe_extract_page(%{extraction_status: "pending"} = page) do
    case process_page_extraction(page) do
      :ok -> Documents.get_page!(page.id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_extract_page(page), do: page

  defp maybe_translate_and_continue(page, document_id, cancelled_documents) do
    if page.extraction_status == "completed" && page.translation_status == "pending" do
      case process_page_translation(page) do
        :ok -> process_next_page(document_id, cancelled_documents)
        {:error, reason} -> {:error, reason}
      end
    else
      process_next_page(document_id, cancelled_documents)
    end
  end

  defp process_page_extraction(page, retry_count \\ 0) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "processing"})
    Documents.broadcast_page_update(page)

    image_path = Path.join(Documents.uploads_dir(), page.image_path)

    case ollama_module().extract_markdown(image_path, []) do
      {:ok, markdown} ->
        {:ok, page} =
          Documents.update_page_extraction(page, %{
            original_markdown: markdown,
            extraction_status: "completed"
          })

        Documents.broadcast_page_update(page)
        EmbeddingWorker.generate_embedding(page.id)
        :ok

      {:error, reason} ->
        handle_extraction_error(page, reason, retry_count)
    end
  end

  defp handle_extraction_error(page, _reason, retry_count) when retry_count < @max_retries do
    Logger.warning(
      "Extraction failed for page #{page.page_number}, retrying (#{retry_count + 1}/#{@max_retries})"
    )

    Process.sleep(1_000)
    process_page_extraction(page, retry_count + 1)
  end

  defp handle_extraction_error(page, reason, _retry_count) do
    Logger.error(
      "Extraction failed for page #{page.page_number} after #{@max_retries} retries: #{reason}"
    )

    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "error"})
    Documents.broadcast_page_update(page)

    {:error,
     dgettext("errors", "Page %{page_number} extraction failed: %{reason}",
       page_number: page.page_number,
       reason: reason
     )}
  end

  defp process_page_translation(page, retry_count \\ 0) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Documents.broadcast_page_update(page)

    document = Documents.get_document!(page.document_id)

    case ollama_module().translate(page.original_markdown, document.target_language, []) do
      {:ok, translated} ->
        {:ok, page} =
          Documents.update_page_translation(page, %{
            translated_markdown: translated,
            translation_status: "completed"
          })

        Documents.broadcast_page_update(page)
        :ok

      {:error, reason} ->
        handle_translation_error(page, reason, retry_count)
    end
  end

  defp handle_translation_error(page, _reason, retry_count) when retry_count < @max_retries do
    Logger.warning(
      "Translation failed for page #{page.page_number}, retrying (#{retry_count + 1}/#{@max_retries})"
    )

    Process.sleep(1_000)
    process_page_translation(page, retry_count + 1)
  end

  defp handle_translation_error(page, reason, _retry_count) do
    Logger.error(
      "Translation failed for page #{page.page_number} after #{@max_retries} retries: #{reason}"
    )

    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "error"})
    Documents.broadcast_page_update(page)

    {:error,
     dgettext("errors", "Page %{page_number} translation failed: %{reason}",
       page_number: page.page_number,
       reason: reason
     )}
  end
end
