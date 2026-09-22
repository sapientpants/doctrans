defmodule Doctrans.Processing.Cancellation do
  @moduledoc """
  Stops a document's processing without deleting the document.

  Cancellation is a statement about work that has not started. `Worker` cancels
  the document's `available`, `scheduled` and `retryable` jobs; a job already
  `executing` is out of Oban's reach and runs to completion. That straggler is
  why the document's own status matters: `cancelled` is a terminal state the
  orchestrator refuses to overturn, so a job finishing after the fact cannot
  report the document completed or failed.

  Nothing generated is discarded. The pages keep the content they produced, and
  the document stays reprocessable — as a whole, or page by page — so recovering
  from a cancellation never means uploading the file again.
  """

  import Ecto.Query

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Errors
  alias Doctrans.Processing.{Run, Worker}
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

    # `Worker` already spans both job shapes, document-keyed and page-keyed;
    # restating its query here would be a second definition of the same rule.
    case Worker.cancel_document(document.id) do
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
