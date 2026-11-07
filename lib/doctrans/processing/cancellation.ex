defmodule Doctrans.Processing.Cancellation do
  @moduledoc """
  Stops a document's processing, on its own or ahead of deleting the document.

  Cancellation is a statement about work that has not started. `cancel_jobs/1`
  cancels the document's waiting jobs — `available`, `scheduled`, `retryable`
  and `suspended`, as `JobQuery.waiting_states/0` lists them; a job already
  `executing` is out of Oban's reach and runs to completion. That
  straggler is why the document's own status matters: `cancelled` is a terminal
  state `Doctrans.Documents.Lifecycle` refuses to leave on a job's account, so a
  job finishing after the fact -- succeeding, or failing on its last attempt --
  cannot report the document completed or failed.

  Nothing generated is discarded by `cancel_document/1`. The pages keep the
  content they produced, and the document stays reprocessable — as a whole, or
  page by page — so recovering from a cancellation never means uploading the file
  again. `cancel_and_delete/1` is the one call here that does discard: it is what
  deleting a document means from the user's side, the queued work stopped before
  the row and files go.
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Lifecycle, PageLifecycle}
  alias Doctrans.Errors
  alias Doctrans.Processing.{JobQuery, Run}
  alias Doctrans.Repo

  @doc """
  Cancels the document's queued work and marks the document `cancelled`.

  Returns `{:error, :not_cancellable}` for a document that has already settled.
  """
  @spec cancel_document(Document.t() | Ecto.UUID.t()) ::
          {:ok, Document.t()} | {:error, Errors.reason()}
  def cancel_document(%Document{} = document), do: cancel_document(document.id)

  def cancel_document(document_id) do
    Repo.safe_transaction(fn -> cancel_locked(document_id) end)
  end

  # The status moves first: a document that has already settled is refused
  # before any job is touched. The transition announces itself once this
  # transaction commits.
  defp cancel_locked(document_id) do
    document = Run.lock!(document_id)

    cancelled =
      case Lifecycle.cancel(document) do
        {:ok, cancelled} -> cancelled
        {:error, reason} -> Repo.rollback(reason)
      end

    case cancel_jobs(document.id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # The jobs that held stages `processing` are gone with the cancellation;
    # the page lifecycle releases those stages so the viewer shows no spinner
    # for work nobody is doing.
    case PageLifecycle.release(cancelled) do
      {:ok, _pages} -> cancelled
      {:error, reason} -> Repo.rollback(reason)
    end
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
end
