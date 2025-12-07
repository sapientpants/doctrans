defmodule Doctrans.Processing.LlmProcessor do
  @moduledoc """
  Handles LLM-based processing of individual pages.

  Performs markdown extraction and translation using Ollama models.
  Each page is processed independently: first extraction, then translation.

  ## I18n Note

  This module runs in background GenServer processes (document processing pipeline),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
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
  Processes a single page through the LLM pipeline (extraction + translation).

  Returns `:ok` or `{:error, reason}`.
  """
  def process_page(page_id, cancelled_documents) do
    case Documents.get_page(page_id) do
      nil ->
        {:error, dgettext("errors", "Page not found")}

      page ->
        if MapSet.member?(cancelled_documents, page.document_id) do
          Logger.info("Document #{page.document_id} was cancelled, skipping page #{page_id}")
          :ok
        else
          do_process_page(page)
        end
    end
  end

  defp do_process_page(page) do
    with :ok <- maybe_extract(page),
         page <- Documents.get_page!(page.id) do
      maybe_translate(page)
    end
  end

  defp maybe_extract(%{extraction_status: "pending"} = page) do
    process_page_extraction(page)
  end

  defp maybe_extract(_page), do: :ok

  defp maybe_translate(%{extraction_status: "completed", translation_status: "pending"} = page) do
    process_page_translation(page)
  end

  defp maybe_translate(_page), do: :ok

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
