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
  alias Doctrans.Documents.{Formats, Lifecycle}
  alias Doctrans.Processing.{PdfProcessor, Run}

  @doc """
  Extracts the stored source of the run a job was queued under.

  The extraction job's entry point. A document that is gone answers
  `{:error, :document_not_found}`. One that has moved on to another run, or
  settled while the job was waiting, is not that job's to act on and answers
  `:ok`, as does an extraction the lifecycle refuses for the same reasons. A
  source that is not there -- `Run.source_path/1` is nil for an extension that
  is not a supported source format, which is reported like a file that is
  missing -- fails the document and answers `{:error, :document_file_not_found}`.
  """
  @spec extract_current(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          :ok | {:error, Doctrans.Errors.reason()}
  def extract_current(document_id, run_id) do
    case Documents.get_document(document_id) do
      nil -> {:error, :document_not_found}
      document -> if Run.current?(document, run_id), do: extract_source(document), else: :ok
    end
  end

  defp extract_source(document) do
    path = Run.source_path(document)

    if path && File.regular?(path) do
      case extract_document(document.id, path, document) do
        {:error, reason} when reason in [:obsolete_run, :already_settled] -> :ok
        result -> result
      end
    else
      _ = Lifecycle.fail(document, :document_file_not_found)
      {:error, :document_file_not_found}
    end
  end

  @doc """
  Extracts pages from a document and creates page records progressively.


  Supports PDF, Word (.docx, .doc), OpenDocument (.odt), and Rich Text Format (.rtf).
  Non-PDF documents are converted to PDF before extraction.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec extract_document(Ecto.UUID.t(), String.t(), Documents.Document.t() | nil) ::
          :ok | {:error, Doctrans.Errors.reason()}
  def extract_document(document_id, file_path, document \\ nil) do
    document = document || Documents.get_document(document_id)

    with {:ok, document} <- prepare_document(document) do
      process_source(document_id, file_path, document)
    end
  end

  defp prepare_document(nil), do: {:error, :document_not_found}
  defp prepare_document(%{processing_run_id: nil} = document), do: {:ok, document}

  defp prepare_document(document), do: Lifecycle.begin_extraction(document)

  defp process_source(document_id, file_path, document) do
    extension = Formats.extension(file_path)

    cond do
      extension == ".pdf" ->
        PdfProcessor.extract_document(document_id, file_path, document)

      extension in Formats.convertible_extensions() ->
        convert_and_extract(document_id, file_path, document)

      true ->
        Logger.error("Unsupported file format: #{extension}")
        {:error, {:unsupported_format, [format: extension]}}
    end
  end

  # The job path is the fixed original.<validated extension> path created during
  # upload, the stored original; output is a directory derived from persisted UUIDs.
  # sobelow_skip ["Traversal.FileModule"]
  defp convert_and_extract(document_id, file_path, document) do
    output_dir = if document, do: Run.output_dir(document), else: Path.dirname(file_path)
    File.mkdir_p!(output_dir)

    Logger.info("Converting document #{file_path} to PDF")

    case Deps.document_converter().convert_to_pdf(file_path, output_dir) do
      {:ok, pdf_path} ->
        PdfProcessor.extract_document(document_id, pdf_path, document)

      {:error, reason} ->
        Logger.error("Failed to convert document #{document_id}: #{inspect(reason)}")
        # Preserve the source for the persisted job's next attempt or manual recovery.
        _ = Lifecycle.fail(document, reason)
        {:error, reason}
    end
  end
end
