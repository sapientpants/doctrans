defmodule Doctrans.Processing.PdfProcessor do
  @moduledoc """
  Handles PDF extraction and page creation for documents.

  Extracts pages progressively - each page is extracted and its record created
  before moving to the next page. This enables:
  - Immediate thumbnail availability (first page)
  - Progressive UI updates as pages are extracted
  - Early total_pages availability for progress tracking
  """

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker

  # Allow PdfExtractor module to be configured for testing
  defp pdf_extractor_module do
    Application.get_env(:doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractor)
  end

  @doc """
  Extracts pages from a PDF and creates page records progressively.

  Returns `:ok`, `:cancelled`, or `{:error, reason}`.
  """
  def extract_document(document_id, pdf_path, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping PDF extraction")
      File.rm(pdf_path)
      :cancelled
    else
      do_extract(document_id, pdf_path)
    end
  end

  defp do_extract(document_id, pdf_path) do
    with {:ok, document} <- fetch_document(document_id),
         :ok <- extract_pdf_pages(document, pdf_path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to extract PDF for document #{document_id}: #{reason}")
        maybe_update_error(document_id, reason)
        {:error, reason}
    end
  end

  defp fetch_document(document_id) do
    case Documents.get_document(document_id) do
      nil -> {:error, dgettext("errors", "Document not found")}
      document -> {:ok, document}
    end
  end

  defp maybe_update_error(document_id, reason) do
    case Documents.get_document(document_id) do
      nil -> :ok
      document -> Documents.update_document_status(document, "error", reason)
    end
  end

  defp extract_pdf_pages(document, pdf_path) do
    Logger.info("Extracting pages from PDF for document #{document.id}")

    pages_dir = Documents.ensure_document_dirs!(document.id)

    # Get page count early so UI can show progress
    with {:ok, page_count} <- pdf_extractor_module().get_page_count(pdf_path),
         {:ok, document} <- set_total_pages(document, page_count),
         :ok <- extract_pages_progressively(document, pdf_path, pages_dir, page_count) do
      Logger.info("Extracted #{page_count} pages for document #{document.id}")

      # Delete the original PDF to save space
      File.rm(pdf_path)

      :ok
    else
      {:error, reason} ->
        {:error, dgettext("errors", "PDF extraction failed: %{reason}", reason: reason)}
    end
  end

  defp set_total_pages(document, page_count) do
    case Documents.update_document(document, %{total_pages: page_count}) do
      {:ok, updated_document} ->
        Documents.broadcast_document_update(updated_document)
        {:ok, updated_document}

      error ->
        error
    end
  end

  defp extract_pages_progressively(document, pdf_path, pages_dir, page_count) do
    result =
      Enum.reduce_while(1..page_count, :ok, fn page_number, :ok ->
        case extract_and_create_page(document, pdf_path, pages_dir, page_number) do
          {:ok, page} ->
            # Queue page for LLM processing immediately
            queue_page_for_processing(page)
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    # Final broadcast after all pages are extracted
    Documents.broadcast_document_update(document)

    result
  end

  defp queue_page_for_processing(page) do
    Logger.info("Queueing page #{page.page_number} for LLM processing")
    Worker.queue_page(page.id)
  end

  defp extract_and_create_page(document, pdf_path, pages_dir, page_number) do
    case pdf_extractor_module().extract_page(pdf_path, pages_dir, page_number, []) do
      {:ok, image_path} ->
        relative_path = Path.relative_to(image_path, Documents.uploads_dir())
        page_attrs = %{page_number: page_number, image_path: relative_path}

        case Documents.create_page(document, page_attrs) do
          {:ok, page} ->
            # Broadcast page creation for progressive UI updates
            Documents.broadcast_page_update(page)
            {:ok, page}

          {:error, changeset} ->
            {:error, "Failed to create page record: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
