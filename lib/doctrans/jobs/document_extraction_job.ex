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
  alias Doctrans.Documents.{Lifecycle, Topics}
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

  @doc """
  Queues a fresh upload: records the extension its stored file was validated
  under, requeues it through `Lifecycle.requeue/2`, and inserts the extraction
  job, in one transaction. The queued document is announced once that
  transaction has committed.

  Only a document still `uploading` is taken. One whose run has started --
  under way or settled -- is refused with `{:error, :already_processing}`:
  replacing a settled run also discards its pages and chat context, which is
  `Doctrans.Processing.DocumentReprocessing`'s to do.
  """
  @spec enqueue_document(Ecto.UUID.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_document(document_id, file_path) do
    with {:ok, {queued, job}} <- Repo.safe_transaction(fn -> requeue(document_id, file_path) end) do
      _ = Topics.broadcast_document_updated(queued)
      {:ok, job}
    end
  end

  # `Lifecycle` does not announce a write made inside the caller's transaction,
  # which is why `enqueue_document/2` announces the queued document itself.
  defp requeue(document_id, file_path) do
    document = Run.lock(document_id) || Repo.rollback(:document_not_found)
    unless Lifecycle.uploading?(document), do: Repo.rollback(:already_processing)

    queued =
      with {:ok, recorded} <- Run.record_source_extension(document, file_path),
           {:ok, queued} <- Lifecycle.requeue(recorded, Run.new_attrs()) do
        queued
      else
        {:error, reason} -> Repo.rollback(reason)
      end

    {queued, queued |> Run.args() |> new() |> Repo.insert_job!()}
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
  # source format, which is reported like a source that is not there. A run the
  # document has moved on from, or a document that settled while this job was
  # waiting, is not this job's to act on: both are dropped as a success.
  defp extract_from(document, path) do
    if path && File.regular?(path) do
      case DocumentProcessor.extract_document(document.id, path, document) do
        {:error, reason} when reason in [:obsolete_run, :already_settled] -> :ok
        result -> result
      end
    else
      report_missing_source(document)
    end
  end

  defp report_missing_source(document) do
    _ = Lifecycle.fail(document, :document_file_not_found)
    {:error, :document_file_not_found}
  end
end
