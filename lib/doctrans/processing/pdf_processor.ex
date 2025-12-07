defmodule Doctrans.Processing.PdfProcessor do
  @moduledoc """
  Handles PDF extraction and page creation for documents.
  """

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Documents

  # Allow PdfExtractor module to be configured for testing
  defp pdf_extractor_module do
    Application.get_env(:doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractor)
  end

  @doc """
  Extracts pages from a PDF and creates page records.

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

    case pdf_extractor_module().extract_pages(pdf_path, pages_dir, []) do
      {:ok, page_count} ->
        Logger.info("Extracted #{page_count} pages for document #{document.id}")
        create_page_records(document, page_count, pages_dir, pdf_path)

      {:error, reason} ->
        {:error, dgettext("errors", "PDF extraction failed: %{reason}", reason: reason)}
    end
  end

  defp create_page_records(document, page_count, pages_dir, pdf_path) do
    {:ok, document} = Documents.update_document(document, %{total_pages: page_count})

    page_images = pdf_extractor_module().list_page_images(pages_dir)

    page_attrs =
      page_images
      |> Enum.with_index(1)
      |> Enum.map(fn {image_path, page_number} ->
        relative_path = Path.relative_to(image_path, Documents.uploads_dir())
        %{page_number: page_number, image_path: relative_path}
      end)

    Documents.create_pages(document, page_attrs)

    # Delete the original PDF to save space
    File.rm(pdf_path)

    Documents.broadcast_document_update(document)

    :ok
  end
end
