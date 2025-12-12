defmodule Doctrans.Jobs.PdfExtractionJob do
  @moduledoc """
  Job for extracting PDF pages in the background.
  This job processes a PDF document and extracts individual pages
  as images for further processing.
  """

  use Oban.Worker, queue: :pdf_extraction, max_attempts: 3

  alias Doctrans.Documents
  alias Doctrans.Processing.PdfProcessor

  @impl true
  def perform(%Oban.Job{args: %{"document_id" => document_id, "pdf_path" => pdf_path}}) do
    PdfProcessor.extract_document(document_id, pdf_path, MapSet.new())
  end

  @impl true
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    # For cases where PDF path is not provided (e.g., retries)
    case Documents.get_document(document_id) do
      nil ->
        {:error, "Document not found"}

      _doc ->
        pdf_path = PdfProcessor.get_pdf_path(document_id)
        PdfProcessor.extract_document(document_id, pdf_path, MapSet.new())
    end
  end
end
