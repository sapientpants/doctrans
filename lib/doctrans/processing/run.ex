defmodule Doctrans.Processing.Run do
  @moduledoc """
  A fresh upload's run, the models and the job a run runs under, and the fence
  on a document's run.

  A run's extraction job is inserted here and nowhere else: `start/2` starts
  the run of a fresh upload, `replace/2` the run a reprocess puts in a settled
  one's place, and `recover/1` re-queues the job of a run a boot found still
  owed. `Doctrans.Jobs.DocumentExtractionJob` is the row they insert and the
  `perform/1` that hands the document to `Doctrans.Processing.Extraction`, and
  decides nothing about the run itself.

  The fence (`lock/1`, `current?/2`, `with_current/2`, `with_page/2`) lives in
  `Doctrans.Documents.Revision`, which owns the revision columns it compares.
  It is delegated here so the Processing and Jobs contexts have one door for
  run concerns: they name `Run`, and only `Run`, for it; the Documents, Chat
  and Search contexts name `Revision` directly.
  """
  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents.{Document, Lifecycle, Revision, Source}
  alias Doctrans.Errors
  alias Doctrans.Jobs.{DocumentExtractionJob, Keys, RunCleanupJob}
  alias Doctrans.Repo

  @doc """
  Takes a fresh upload through its requeue.

  In one transaction: records the format the stored file was validated under
  through `Doctrans.Documents.Source`, requeues the document through
  `Doctrans.Documents.Lifecycle.requeue/2` under a new run id and the
  configured models, and inserts the extraction job. The transition announces
  the queued document once that transaction has committed.

  Only a document still `uploading` is taken. One whose run has started -- under
  way or settled -- is refused with `{:error, :already_processing}`: replacing a
  settled run also discards its pages and chat context, which is
  `Doctrans.Processing.DocumentReprocessing`'s to do.
  """
  @spec start(Ecto.UUID.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, Errors.reason()}
  def start(document_id, source_path) do
    Repo.safe_transaction(fn -> start_locked(document_id, source_path) end)
  end

  defp start_locked(document_id, source_path) do
    document = lock!(document_id)
    unless Lifecycle.uploading?(document), do: Repo.rollback(:already_processing)

    document
    |> Source.record_extension(source_path)
    |> Repo.or_rollback()
    |> Lifecycle.requeue(new_attrs([]))
    |> Repo.or_rollback()
    |> enqueue()
  end

  @spec choices(keyword()) :: %{extraction_model: String.t(), translation_model: String.t()}
  def choices(opts \\ []) do
    %{
      extraction_model: Keyword.get(opts, :extraction_model) || OpenAI.vision_model(),
      translation_model: Keyword.get(opts, :translation_model) || OpenAI.translation_model()
    }
  end

  @doc """
  Replaces the run a settled document holds with a new one, inside the
  caller's transaction.

  `document` is the row the caller has locked and found eligible; what the
  replaced run left behind -- its pages, its chat context -- is the caller's to
  discard first. The document is requeued through
  `Doctrans.Documents.Lifecycle.requeue/2` under a new run id and the models
  chosen in `opts` (the configured defaults for any not chosen), then its
  extraction job and the cleanup of the replaced run's files are inserted. A
  document whose run is under way is refused with `:already_processing`; a job
  already waiting for the document rolls the caller's transaction back with
  the same reason, so the run and its jobs always commit together.
  """
  @spec replace(Document.t(), keyword()) :: {:ok, Document.t()} | {:error, Errors.reason()}
  def replace(%Document{} = document, opts \\ []) do
    with {:ok, queued} <- Lifecycle.requeue(document, new_attrs(opts)) do
      _ = enqueue(queued, cleanup: true)
      {:ok, queued}
    end
  end

  @doc """
  Re-queues the extraction job of the run `document` already holds, for a boot
  that found the document still awaiting its pages.

  The job is marked `recovered`. A job already active for the document is left
  to finish and answered `{:ok, :owned}`; nothing about the run changes either
  way. The caller holds the document lock and decides what is owed.
  """
  @spec recover(Document.t()) :: {:ok, :queued | :owned} | {:error, Errors.reason()}
  def recover(%Document{} = document) do
    document
    |> args()
    |> DocumentExtractionJob.new(meta: %{recovered: true})
    |> Oban.insert()
    |> case do
      {:ok, %Oban.Job{conflict?: true}} -> {:ok, :owned}
      {:ok, %Oban.Job{}} -> {:ok, :queued}
      {:error, _reason} = error -> Errors.result(error)
    end
  end

  # A new run: a fresh id and the models it will use.
  defp new_attrs(opts), do: Map.put(choices(opts), :processing_run_id, Uniq.UUID.uuid7())

  # The argument map `DocumentExtractionJob.perform/1` and `RunCleanupJob.perform/1`
  # destructure: the document and the run the job acts for.
  defp args(document),
    do: %{Keys.document_id() => document.id, "run_id" => document.processing_run_id}

  # Inside the transaction that made the requeue transition, so the run and
  # its jobs commit together; a job already waiting for the document rolls
  # that transaction back with `:already_processing`.
  defp enqueue(document, opts \\ []) do
    args = args(document)
    job = args |> DocumentExtractionJob.new() |> Repo.insert_job!()

    _ =
      if Keyword.get(opts, :cleanup, false), do: args |> RunCleanupJob.new() |> Repo.insert_job!()

    job
  end

  @doc """
  Locks the document row for the current transaction, or rolls the transaction
  back with `:document_not_found` when it is gone: the first line of every
  transaction that works on a document's run.
  """
  @spec lock!(Ecto.UUID.t()) :: Document.t()
  def lock!(document_id), do: lock(document_id) || Repo.rollback(:document_not_found)

  defdelegate lock(document_id), to: Revision
  defdelegate current?(document, run_id), to: Revision
  defdelegate with_current(document, fun), to: Revision
  defdelegate with_page(page, fun), to: Revision
end
