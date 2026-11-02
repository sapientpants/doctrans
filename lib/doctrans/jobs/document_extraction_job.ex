defmodule Doctrans.Jobs.DocumentExtractionJob do
  @moduledoc """
  Job for extracting document pages in the background.

  This job processes documents (PDF, Word, etc.) and extracts individual pages
  as images for further processing. For non-PDF formats, the document is first
  converted to PDF before extraction.
  """

  use Oban.Worker,
    queue: :pdf_extraction,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Config.PdfExtraction
  alias Doctrans.Documents
  alias Doctrans.Documents.{Formats, Topics}
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.DocumentProcessor
  alias Doctrans.Processing.Run
  alias Doctrans.Repo
  alias Doctrans.Resilience.ErrorClassifier

  @document_id_key Keys.document_id()

  # Oban waits forever by default. Extraction bounds each poppler run separately,
  # but a document is many runs, so the job carries its own ceiling — the same one
  # the extractor clamps each page render against. Pages already rendered stay on
  # disk and their records stay in the database, so the retry this produces
  # resumes the document instead of restarting it.
  @impl true
  def timeout(_job), do: PdfExtraction.job_timeout()

  @spec enqueue_document(Ecto.UUID.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_document(document_id, file_path) do
    Repo.transaction(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)

      # This is the stored upload path, whose extension passed magic-byte validation.
      extension = Formats.extension(file_path)

      unless Formats.supported?(extension),
        do: Repo.rollback({:unsupported_format, [format: extension]})

      document =
        document
        |> Ecto.Changeset.change(source_extension: document.source_extension || extension)
        |> Repo.update!()

      document =
        if document.processing_run_id do
          document
        else
          document |> Ecto.Changeset.change(Run.new_attrs()) |> Repo.update!()
        end

      case document |> Run.args() |> new() |> Oban.insert() do
        {:ok, job} -> job
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Doctrans.Errors.result()
  end

  # A document row that is gone stays gone, so the job is cancelled rather than
  # spent on retries that find the same absence.
  @impl true
  def perform(%Oban.Job{args: %{@document_id_key => document_id} = args}) do
    case Documents.get_document(document_id) do
      nil -> {:cancel, :document_not_found}
      document -> document |> perform_current(args) |> cancel_permanent()
    end
  end

  # A failure that cannot come out differently on a retry — the document is over
  # a limit, a tool is not installed, the source file is gone — is cancelled with
  # the reason intact. Retrying it would burn the document's remaining attempts
  # and occupy the single extraction slot to reach the same answer.
  defp cancel_permanent({:error, reason}) do
    if ErrorClassifier.retryable?(reason), do: {:error, reason}, else: {:cancel, reason}
  end

  defp cancel_permanent(result), do: result

  defp perform_current(document, args) do
    if Run.current?(document, Map.get(args, "run_id")) do
      extract_from(document, Run.source_path(document))
    else
      :ok
    end
  end

  # `Run.source_path/1` is nil for a document whose extension is not a supported
  # source format, which is reported like a source that is not there.
  defp extract_from(document, path) do
    if path && File.regular?(path) do
      case DocumentProcessor.extract_document(document.id, path, document) do
        {:error, :obsolete_run} -> :ok
        result -> result
      end
    else
      report_missing_source(document)
    end
  end

  defp report_missing_source(document) do
    _ =
      with {:ok, updated} <-
             Documents.update_document_status(document, "error", :document_file_not_found) do
        Topics.broadcast_document_updated(updated)
      end

    {:error, :document_file_not_found}
  end
end
