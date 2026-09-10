defmodule Doctrans.Processing.PdfProcessor do
  @moduledoc """
  Handles PDF extraction and page creation for documents.

  Extracts pages progressively - each page is extracted and its record created
  before moving to the next page. This enables:
  - Immediate thumbnail availability (first page)
  - Progressive UI updates as pages are extracted
  - Early total_pages availability for progress tracking

  Retries reuse stored pages and images and queue only unfinished processing.
  """

  require Logger

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.{Run, Worker}

  # Allow PdfExtractor module to be configured for testing
  defp pdf_extractor_module do
    Application.get_env(:doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractor)
  end

  @doc """
  Extracts pages from a PDF and creates page records progressively.

  Returns `:ok`, `:cancelled`, or `{:error, reason}`.
  """
  # pdf_path is the stored original upload or the converter output in the same document directory.
  # sobelow_skip ["Traversal.FileModule"]
  def extract_document(document_id, pdf_path, cancelled_documents, document \\ nil) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping PDF extraction")
      :cancelled
    else
      do_extract(document_id, pdf_path, document || Documents.get_document(document_id))
    end
  end

  defp do_extract(document_id, pdf_path, document) do
    with {:ok, document} <- fetch_document(document_id, document),
         {:ok, document} <- resume_failed_document(document),
         :ok <- extract_pdf_pages(document, pdf_path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to extract PDF for document #{document_id}: #{inspect(reason)}")
        maybe_update_error(document, reason)
        {:error, reason}
    end
  end

  defp resume_failed_document(%{status: "error"} = document) do
    # Restore processing before queueing pages so retries can publish live progress.
    with {:ok, document} <- Documents.update_document_status(document, "processing") do
      _ = Topics.broadcast_document_update(document)
      {:ok, document}
    end
  end

  defp resume_failed_document(document), do: {:ok, document}

  defp fetch_document(_document_id, %Documents.Document{} = document), do: {:ok, document}

  defp fetch_document(document_id, nil) do
    case Documents.get_document(document_id) do
      nil -> {:error, :document_not_found}
      document -> {:ok, document}
    end
  end

  defp maybe_update_error(document, reason) do
    if document, do: Documents.update_document_status(document, "error", reason), else: :ok
  end

  @doc """
  Gets the expected PDF file path for a document.

  Returns the path where the PDF would be stored, based on the configured
  upload directory and document ID. Note that this returns the expected path
  regardless of whether the file actually exists on disk.
  """
  def get_pdf_path(document_id) do
    Path.join([
      Uploads.upload_dir(),
      "#{document_id}.pdf"
    ])
  end

  # The output path is built from persisted document/run UUIDs with a fixed pages suffix.
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_pdf_pages(document, pdf_path) do
    Logger.info("Extracting pages from PDF for document #{document.id}")

    pages_dir = Run.pages_dir(document)
    File.mkdir_p!(pages_dir)

    # Get page count early so UI can show progress
    with {:ok, page_count} <- pdf_extractor_module().get_page_count(pdf_path),
         {:ok, document} <- set_total_pages(document, page_count),
         :ok <- extract_pages_progressively(document, pdf_path, pages_dir, page_count) do
      Logger.info("Extracted #{page_count} pages for document #{document.id}")

      :ok
    else
      {:error, reason} ->
        {:error, {:pdf_extraction_failed, [reason: reason]}}
    end
  end

  defp set_total_pages(document, page_count) do
    case Documents.update_document(document, %{total_pages: page_count}) do
      {:ok, updated_document} ->
        _ = Topics.broadcast_document_update(updated_document)
        {:ok, updated_document}

      error ->
        error
    end
  end

  defp extract_pages_progressively(document, pdf_path, pages_dir, page_count) do
    result =
      Enum.reduce_while(1..page_count, :ok, fn page_number, :ok ->
        with {:ok, page} <- ensure_page(document, pdf_path, pages_dir, page_number),
             :ok <-
               Run.with_current(document, fn current ->
                 queue_page_for_processing(page, current)
               end) do
          {:cont, :ok}
        else
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    if result == :ok, do: finish_extraction(document), else: result
  end

  defp finish_extraction(document) do
    Run.with_current(document, fn current ->
      if current.status in ~w(uploading queued extracting error) do
        with {:ok, current} <- Documents.update_document_status(current, "processing") do
          Topics.broadcast_document_update(current)
        end
      end

      :ok
    end)
  end

  defp queue_page_for_processing(
         %{
           extraction_status: "completed",
           translation_status: "completed"
         },
         _document
       ),
       do: :ok

  defp queue_page_for_processing(page, document) do
    Logger.info("Queueing page #{page.page_number} for LLM processing")
    # Oban uniqueness preserves any active job, including its retry state.
    case Worker.queue_page(page.id, [page_number: page.page_number] ++ Run.model_opts(document)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_page(document, pdf_path, pages_dir, page_number) do
    page = Documents.get_page_by_number(document.id, page_number)

    if page && is_binary(page.image_path) &&
         File.regular?(Path.join(Documents.uploads_dir(), page.image_path)) do
      {:ok, page}
    else
      extract_and_save_page(document, page, pdf_path, pages_dir, page_number)
    end
  end

  defp extract_and_save_page(document, page, pdf_path, pages_dir, page_number) do
    case pdf_extractor_module().extract_page(pdf_path, pages_dir, page_number, []) do
      {:ok, image_path} ->
        relative_path = Path.relative_to(image_path, Documents.uploads_dir())
        page_attrs = %{page_number: page_number, image_path: relative_path}

        case Run.with_current(document, fn current -> save_page(current, page, page_attrs) end) do
          {:ok, page} ->
            # Broadcast page creation for progressive UI updates
            Topics.broadcast_page_update(page)
            {:ok, page}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_page(document, nil, attrs), do: Documents.create_page(document, attrs)
  defp save_page(_document, page, attrs), do: Documents.update_page(page, attrs)
end
