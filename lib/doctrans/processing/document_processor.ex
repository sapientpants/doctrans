defmodule Doctrans.Processing.DocumentProcessor do
  @moduledoc """
  Handles document extraction regardless of source format.

  Routes documents to appropriate processors based on file type:
  - PDF files are processed directly via PdfProcessor
  - the other formats in `Doctrans.Documents.Formats` -- Word, OpenDocument and
    Rich Text -- are converted to PDF first, then processed

  This provides a unified interface for document processing while supporting
  multiple input formats.
  """

  require Logger

  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.{Formats, Topics}
  alias Doctrans.Processing.{PdfProcessor, Run}

  @doc """
  Extracts pages from a document and creates page records progressively.

  Supports PDF, Word (.docx, .doc), OpenDocument (.odt), and Rich Text Format (.rtf).
  Non-PDF documents are converted to PDF before extraction.

  Returns `:ok`, `:cancelled`, or `{:error, reason}`.
  """
  @spec extract_document(
          Ecto.UUID.t(),
          String.t(),
          MapSet.t(Ecto.UUID.t()),
          Documents.Document.t() | nil
        ) :: :ok | :cancelled | {:error, Doctrans.Errors.reason()}
  def extract_document(document_id, file_path, cancelled_documents, document \\ nil) do
    document = document || Documents.get_document(document_id)

    with {:ok, document} <- prepare_document(document) do
      process_source(document_id, file_path, cancelled_documents, document)
    end
  end

  defp prepare_document(nil), do: {:error, :document_not_found}
  defp prepare_document(%{processing_run_id: nil} = document), do: {:ok, document}

  defp prepare_document(document) do
    with {:ok, document} <- Documents.update_document_status(document, "extracting") do
      _ = Topics.broadcast_document_updated(document)
      {:ok, document}
    end
  end

  defp process_source(document_id, file_path, cancelled_documents, document) do
    extension = Formats.extension(file_path)

    cond do
      extension == ".pdf" ->
        PdfProcessor.extract_document(document_id, file_path, cancelled_documents, document)

      extension in Formats.convertible_extensions() ->
        extract_convertible_document(document_id, file_path, cancelled_documents, document)

      true ->
        Logger.error("Unsupported file format: #{extension}")
        {:error, {:unsupported_format, [format: extension]}}
    end
  end

  # The job path is the fixed original.<validated extension> path created during upload;
  # the File calls themselves live in do_convert_and_extract/4.
  defp extract_convertible_document(document_id, file_path, cancelled_documents, document) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping conversion")

      :cancelled
    else
      do_convert_and_extract(document_id, file_path, cancelled_documents, document)
    end
  end

  # Source is the stored original upload; output is a directory derived from persisted UUIDs.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_convert_and_extract(document_id, file_path, cancelled_documents, document) do
    output_dir = if document, do: Run.output_dir(document), else: Path.dirname(file_path)
    File.mkdir_p!(output_dir)

    Logger.info("Converting document #{file_path} to PDF")

    case Deps.document_converter().convert_to_pdf(file_path, output_dir) do
      {:ok, pdf_path} ->
        PdfProcessor.extract_document(document_id, pdf_path, cancelled_documents, document)

      {:error, reason} ->
        Logger.error("Failed to convert document #{document_id}: #{inspect(reason)}")
        # Preserve the source for the persisted job's next attempt or manual recovery.
        _ = publish_conversion_error(document, reason)
        {:error, reason}
    end
  end

  defp publish_conversion_error(document, reason) do
    with %Documents.Document{} = document <- document,
         {:ok, document} <- Documents.update_document_status(document, "error", reason) do
      _ = Topics.broadcast_document_updated(document)
    end
  end
end
