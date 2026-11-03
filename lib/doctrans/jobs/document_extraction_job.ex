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
  alias Doctrans.Documents.{Formats, Lifecycle, Topics}
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
  Starts the document's run: records the extension the stored upload was
  validated under, moves the document to `queued` through
  `Lifecycle.requeue/2`, and inserts the extraction job, in one transaction.
  The queued document is announced once that transaction has committed.

  Legal where `requeue/2` is -- a fresh upload, or a settled document -- and
  answers `{:error, :already_processing}` for a document whose run is under
  way.
  """
  @spec enqueue_document(Ecto.UUID.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_document(document_id, file_path) do
    Repo.transaction(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)
      queued = document |> record_extension(file_path) |> start_run()
      {queued, insert_job(queued)}
    end)
    |> publish_queued()
    |> Doctrans.Errors.result()
  end

  # `file_path` is the stored upload path, whose extension passed magic-byte
  # validation; a document that already records one keeps it.
  defp record_extension(document, file_path) do
    extension = Formats.extension(file_path)

    unless Formats.supported?(extension),
      do: Repo.rollback({:unsupported_format, [format: extension]})

    document
    |> Ecto.Changeset.change(source_extension: document.source_extension || extension)
    |> Repo.update!()
  end

  defp start_run(document) do
    case Lifecycle.requeue(document, Run.new_attrs()) do
      {:ok, queued} -> queued
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A job already waiting for the document belongs to the run just replaced and
  # would drop the new one as obsolete, so the conflict is a refusal, not a job.
  defp insert_job(document) do
    case document |> Run.args() |> new() |> Oban.insert() do
      {:ok, %{conflict?: false} = job} -> job
      {:ok, _conflicting} -> Repo.rollback(:already_processing)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # `Lifecycle` does not announce a write made inside the caller's transaction,
  # so the queued document is announced here, after the commit.
  defp publish_queued({:ok, {document, job}}) do
    _ = Topics.broadcast_document_updated(document)
    {:ok, job}
  end

  defp publish_queued(error), do: error

  @impl true
  def perform(%Oban.Job{args: %{@document_id_key => document_id} = args}) do
    document_id
    |> DocumentProcessor.extract_current(Map.get(args, "run_id"))
    |> outcome()
  end

  # A failure that cannot come out differently on a retry — the document row is
  # gone, the document is over a limit, a tool is not installed, the source file
  # is gone — is cancelled with the reason intact. Retrying it would burn the
  # document's remaining attempts and occupy the single extraction slot to reach
  # the same answer.
  defp outcome({:error, reason}) do
    if ErrorClassifier.retryable?(reason), do: {:error, reason}, else: {:cancel, reason}
  end

  defp outcome(result), do: result
end
