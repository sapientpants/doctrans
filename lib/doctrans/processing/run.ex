defmodule Doctrans.Processing.Run do
  @moduledoc """
  Where a run starts, the models and the job it runs under, and the fence on
  a document's run.

  `start/2` starts the run of a fresh upload; `Doctrans.Jobs.DocumentExtractionJob`
  is the row it inserts and the `perform/1` that hands the document to
  `Doctrans.Processing.Extraction`, and decides nothing about the run itself.

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
  Starts the run of a fresh upload.

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
    document = lock(document_id) || Repo.rollback(:document_not_found)
    unless Lifecycle.uploading?(document), do: Repo.rollback(:already_processing)

    queued =
      with {:ok, recorded} <- Source.record_extension(document, source_path),
           {:ok, queued} <- Lifecycle.requeue(recorded, new_attrs()) do
        queued
      else
        {:error, reason} -> Repo.rollback(reason)
      end

    enqueue(queued)
  end

  @spec choices(keyword()) :: %{extraction_model: String.t(), translation_model: String.t()}
  def choices(opts \\ []) do
    %{
      extraction_model: Keyword.get(opts, :extraction_model) || OpenAI.vision_model(),
      translation_model: Keyword.get(opts, :translation_model) || OpenAI.translation_model()
    }
  end

  @spec new_attrs(keyword()) :: %{
          extraction_model: String.t(),
          translation_model: String.t(),
          processing_run_id: Ecto.UUID.t()
        }
  def new_attrs(opts \\ []), do: Map.put(choices(opts), :processing_run_id, Uniq.UUID.uuid7())

  @spec args(Document.t()) :: %{String.t() => Ecto.UUID.t() | nil}
  def args(document),
    do: %{Keys.document_id() => document.id, "run_id" => document.processing_run_id}

  @doc """
  Queues the jobs of the run `document` has just been requeued under: its
  extraction job and, with `cleanup: true`, the removal of the files the run
  it replaced left behind. Call inside the transaction that made the
  `Doctrans.Documents.Lifecycle.requeue/2` transition, so the run and its job
  commit together; a job already waiting for the document rolls that
  transaction back with `:already_processing`. Returns the extraction job.
  """
  @spec enqueue(Document.t(), cleanup: boolean()) :: Oban.Job.t()
  def enqueue(document, opts \\ []) do
    args = args(document)
    job = args |> DocumentExtractionJob.new() |> Repo.insert_job!()

    _ =
      if Keyword.get(opts, :cleanup, false), do: args |> RunCleanupJob.new() |> Repo.insert_job!()

    job
  end

  defdelegate lock(document_id), to: Revision
  defdelegate current?(document, run_id), to: Revision
  defdelegate with_current(document, fun), to: Revision
  defdelegate with_page(page, fun), to: Revision
end
