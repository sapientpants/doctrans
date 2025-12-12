defmodule Doctrans.Jobs.DocumentExtractionJob do
  @moduledoc """
  Job for extracting document pages in the background.

  This job processes documents (PDF, Word, etc.) and extracts individual pages
  as images for further processing. For non-PDF formats, the document is first
  converted to PDF before extraction.
  """

  use Oban.Worker, queue: :pdf_extraction, max_attempts: 3

  alias Doctrans.Documents
  alias Doctrans.Processing.DocumentProcessor

  @impl true
  def perform(%Oban.Job{args: %{"document_id" => document_id, "file_path" => file_path}}) do
    DocumentProcessor.extract_document(document_id, file_path, MapSet.new())
  end

  @impl true
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    # For cases where file path is not provided (e.g., retries)
    # Try to find the original file in the document directory
    case Documents.get_document(document_id) do
      nil ->
        {:error, "Document not found"}

      doc ->
        file_path = find_document_file(document_id, doc.original_filename)

        if file_path do
          DocumentProcessor.extract_document(document_id, file_path, MapSet.new())
        else
          {:error, "Document file not found"}
        end
    end
  end

  # Find the document file in the upload directory
  defp find_document_file(document_id, original_filename) do
    upload_dir = Documents.document_upload_dir(document_id)

    # First check for original.pdf (standard naming)
    pdf_path = Path.join(upload_dir, "original.pdf")

    if File.exists?(pdf_path) do
      pdf_path
    else
      # Try to find by original extension
      extension = original_filename |> Path.extname() |> String.downcase()
      original_path = Path.join(upload_dir, "original#{extension}")

      if File.exists?(original_path) do
        original_path
      else
        nil
      end
    end
  end
end
