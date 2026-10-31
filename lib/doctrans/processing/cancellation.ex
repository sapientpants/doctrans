defmodule Doctrans.Processing.Cancellation do
  @moduledoc """
  Stops a document's processing, on its own or ahead of deleting the document.

  Cancellation is a statement about work that has not started. `cancel_jobs/1`
  cancels the document's waiting jobs — `available`, `scheduled`, `retryable`
  and `suspended`, as `JobQuery.waiting_states/0` lists them; a job already
  `executing` is out of Oban's reach and runs to completion. That
  straggler is why the document's own status matters: `cancelled` is a terminal
  state `Completion` refuses to overturn, so a job finishing after the fact
  cannot report the document completed or failed.

  Nothing generated is discarded by `cancel_document/1`. The pages keep the
  content they produced, and the document stays reprocessable — as a whole, or
  page by page — so recovering from a cancellation never means uploading the file
  again. `cancel_and_delete/1` is the one call here that does discard: it is what
  deleting a document means from the user's side, the queued work stopped before
  the row and files go.
  """

  import Ecto.Query

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Errors
  alias Doctrans.Processing.{JobQuery, Run}
  alias Doctrans.Repo

  # Everything else has already settled: cancelling it would rewrite an outcome
  # rather than stop work.
  @in_flight ~w(uploading queued extracting processing)

  @clear_processing "CASE WHEN ? = 'processing' THEN 'pending' ELSE ? END"

  @doc """
  Cancels the document's queued work and marks the document `cancelled`.

  Returns `{:error, :not_cancellable}` for a document that has already settled.
  """
  @spec cancel_document(Document.t() | Ecto.UUID.t()) ::
          {:ok, Document.t()} | {:error, Errors.reason()}
  def cancel_document(%Document{} = document), do: cancel_document(document.id)

  def cancel_document(document_id) do
    transact(fn -> cancel_locked(document_id) end) |> publish()
  end

  defp cancel_locked(document_id) do
    document = Run.lock(document_id) || Repo.rollback(:document_not_found)
    unless document.status in @in_flight, do: Repo.rollback(:not_cancellable)

    case cancel_jobs(document.id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    reset_abandoned_stages(document.id)
    {:ok, cancelled} = Documents.update_document_status(document, "cancelled")
    cancelled
  end

  # The job that owned a `processing` stage is gone, so the stored value would
  # show the viewer a spinner for work nobody is doing. Only the stage markers
  # move: a stage that finished keeps everything it produced.
  defp reset_abandoned_stages(document_id) do
    from(p in Page,
      where: p.document_id == ^document_id,
      where: p.extraction_status == "processing" or p.translation_status == "processing",
      update: [
        set: [
          extraction_status:
            fragment(@clear_processing, p.extraction_status, p.extraction_status),
          translation_status:
            fragment(@clear_processing, p.translation_status, p.translation_status)
        ]
      ]
    )
    |> Repo.update_all([])
  end

  @doc """
  Cancels the document's waiting jobs, then deletes the document and its files.

  `Documents.delete_document/1` on its own would leave the document's queued jobs
  to wake up against a row that is gone. Jobs already executing are out of reach
  and run to completion either way, as `cancel_jobs/1` describes.

  Stops at the first failure, so a cancellation the database refused leaves the
  document in place rather than deleting it with its jobs still queued.
  """
  @spec cancel_and_delete(Document.t()) :: {:ok, Document.t()} | {:error, Errors.reason()}
  def cancel_and_delete(%Document{} = document) do
    with :ok <- cancel_jobs(document.id) do
      Documents.delete_document(document)
    end
  end

  @doc """
  Cancels the document's waiting Oban jobs without touching the document.

  Spans both job shapes, document-keyed (extraction, cleanup) and page-keyed
  (LLM processing, indexing), whatever worker holds them, and leaves executing
  and settled jobs alone. Deleting a document calls this directly: the row is
  about to go, so there is no status left to set.

  Returns `:ok` on success or `{:error, reason}` for database failures.
  Cancellation may be partial if a later query fails. Unexpected errors propagate.
  """
  @spec cancel_jobs(Ecto.UUID.t()) :: :ok | {:error, Errors.reason()}
  def cancel_jobs(document_id) do
    waiting = [states: JobQuery.waiting_states()]

    _ = Oban.cancel_all_jobs(JobQuery.document_jobs_query(document_id, waiting))

    page_ids = for page <- Documents.list_pages(document_id), do: page.id

    _ =
      if page_ids != [],
        do: Oban.cancel_all_jobs(JobQuery.page_jobs_query(page_ids, waiting))

    :ok
  rescue
    error in [Ecto.NoResultsError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "Failed to cancel jobs for document #{document_id}: #{Exception.message(error)}"
      )

      {:error, {:database_error, [reason: error]}}
  end

  # Broadcast after the transaction commits, so subscribers read committed state.
  defp publish({:ok, document}) do
    _ = Topics.broadcast_document_updated(document)
    {:ok, document}
  end

  defp publish(error), do: error

  defp transact(fun) do
    Repo.transaction(fun) |> Errors.result()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, {:database_error, [reason: error]}}
  end
end
