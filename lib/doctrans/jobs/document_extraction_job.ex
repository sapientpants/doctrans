defmodule Doctrans.Jobs.DocumentExtractionJob do
  @moduledoc """
  The Oban side of extraction.

  Enqueueing starts a fresh upload's run; performing hands the document to
  `Doctrans.Processing.Extraction.run/1`, which does the work and makes the
  document's transitions. What is decided here is only what Oban needs to
  know: whether the job still names the document's current run, and whether
  a failure is worth another attempt.
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
  alias Doctrans.Documents.Lifecycle
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.{Extraction, Run}
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
  job, in one transaction; the transition announces the queued document once
  that transaction has committed.

  Only a document still `uploading` is taken. One whose run has started --
  under way or settled -- is refused with `{:error, :already_processing}`:
  replacing a settled run also discards its pages and chat context, which is
  `Doctrans.Processing.DocumentReprocessing`'s to do.
  """
  @spec enqueue_document(Ecto.UUID.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_document(document_id, file_path) do
    Repo.safe_transaction(fn -> requeue(document_id, file_path) end)
  end

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

    Run.enqueue(queued)
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

  # A run the document has moved on from is not this job's to act on, and is
  # dropped as a success; `Extraction` makes the same call for a run replaced
  # or settled while it was under way.
  defp perform_current(document, args) do
    if Run.current?(document, Map.get(args, "run_id")),
      do: Extraction.run(document),
      else: :ok
  end
end
