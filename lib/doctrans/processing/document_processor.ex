defmodule Doctrans.Processing.DocumentProcessor do
  @moduledoc """
  Handles document extraction regardless of source format.

  Routes documents to appropriate processors based on file type:
  - PDF files are processed directly via PdfProcessor
  - Word documents (.docx, .doc) are converted to PDF first, then processed

  This provides a unified interface for document processing while supporting
  multiple input formats.
  """

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Processing.PdfProcessor

  # Allow DocumentConverter module to be configured for testing
  defp document_converter_module do
    Application.get_env(
      :doctrans,
      :document_converter_module,
      Doctrans.Processing.DocumentConverter
    )
  end

  @doc """
  Extracts pages from a document and creates page records progressively.

  Supports PDF and Word document formats. Word documents are converted to PDF
  before extraction.

  Returns `:ok`, `:cancelled`, or `{:error, reason}`.
  """
  def extract_document(document_id, file_path, cancelled_documents) do
    extension = file_path |> Path.extname() |> String.downcase()

    case extension do
      ".pdf" ->
        PdfProcessor.extract_document(document_id, file_path, cancelled_documents)

      ext when ext in [".docx", ".doc", ".odt", ".rtf"] ->
        extract_word_document(document_id, file_path, cancelled_documents)

      _ ->
        Logger.error("Unsupported file format: #{extension}")
        {:error, dgettext("errors", "Unsupported file format: %{format}", format: extension)}
    end
  end

  defp extract_word_document(document_id, file_path, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping conversion")
      File.rm(file_path)
      :cancelled
    else
      do_convert_and_extract(document_id, file_path, cancelled_documents)
    end
  end

  defp do_convert_and_extract(document_id, file_path, cancelled_documents) do
    output_dir = Path.dirname(file_path)

    Logger.info("Converting Word document #{file_path} to PDF")

    case document_converter_module().convert_to_pdf(file_path, output_dir) do
      {:ok, pdf_path} ->
        # Delete the original Word document after successful conversion
        File.rm(file_path)

        # Process the converted PDF
        PdfProcessor.extract_document(document_id, pdf_path, cancelled_documents)

      {:error, reason} ->
        Logger.error("Failed to convert document #{document_id}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Checks if the document processor can handle a given file type.
  """
  def supported_format?(file_path) do
    extension = file_path |> Path.extname() |> String.downcase()
    extension in [".pdf", ".docx", ".doc", ".odt", ".rtf"]
  end

  @doc """
  Returns a list of supported file extensions.
  """
  def supported_extensions do
    [".pdf", ".docx", ".doc", ".odt", ".rtf"]
  end
end
