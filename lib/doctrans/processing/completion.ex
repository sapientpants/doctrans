defmodule Doctrans.Processing.Completion do
  @moduledoc """
  Settles a document from the state of its pages.

  Two transitions live here. `check_document_completion/1` reads the pages after
  one of them changes and moves the document to `completed` or `error` once they
  have all settled. `update_document_status_to_processing/1` moves a document
  out of its pre-processing states when the first page job begins.

  Both are guarded by `Run`, so a job left over from an earlier run cannot
  settle the document the current run owns, and both broadcast only after the
  transaction that holds the document lock has committed. Cancellation and
  reprocessing own their own transitions in `Cancellation` and
  `DocumentReprocessing`; the recovery pass that re-queues interrupted work is
  `StartupRecovery`.
  """

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.{JobStates, Run}

  @doc """
  Resolves the document state from its pages and applies terminal transitions.

  Only fully successful pages complete a document. A document whose pages have
  all settled with at least one failure becomes an error, unless a failed page
  still has a pending retry that may yet succeed (`:retrying`).
  """
  @spec check_document_completion(
          Ecto.UUID.t()
          | Documents.Page.t()
          | Documents.Document.t()
          | nil
        ) ::
          :completed | :failed | :retrying | :incomplete | :cancelled | {:error, :obsolete_run}
  def check_document_completion(nil), do: :incomplete

  def check_document_completion(%Documents.Page{} = page) do
    Run.with_page(page, fn _ -> complete_locked_document(Run.lock(page.document_id)) end)
    |> publish_completion()
  end

  def check_document_completion(%Documents.Document{} = document) do
    Run.with_current(document, &complete_locked_document/1)
    |> publish_completion()
  end

  def check_document_completion(document_id) do
    {:ok, result} =
      Doctrans.Repo.transaction(fn -> complete_locked_document(Run.lock(document_id)) end)

    publish_completion(result)
  end

  defp complete_locked_document(nil), do: :incomplete

  # Cancellation is the user's decision, and a job that was already executing
  # when it was taken still runs to completion. Reading the page states here
  # would let that straggler report the document completed or failed, overturning
  # a stop the user asked for and already saw take effect.
  defp complete_locked_document(%{status: "cancelled"}), do: :cancelled

  defp complete_locked_document(document) do
    case Documents.completion_state(document.id) do
      :completed ->
        {:ok, document} = Documents.update_document_status(document, "completed")
        {:completed, document}

      :failed ->
        settle_failed_document(document)

      :incomplete ->
        :incomplete
    end
  end

  # Keep a scheduled retry distinguishable from terminal failure, and keep the
  # diagnostic a failing page job already recorded.
  defp settle_failed_document(document) do
    cond do
      JobStates.retry_pending?(document.id) ->
        :retrying

      document.status == "error" ->
        :failed

      true ->
        {:ok, document} =
          Documents.update_document_status(document, "error", page_failure_reason(document.id))

        {:failed, document}
    end
  end

  defp page_failure_reason(document_id) do
    page_numbers = Documents.failed_page_numbers(document_id) |> Enum.join(", ")

    {:pages_failed, [page_numbers: page_numbers]}
  end

  # Call after the run/page guard returns, so subscribers can read committed state.
  defp publish_completion({:completed, document}) do
    _ = Topics.broadcast_document_updated(document)
    :completed
  end

  defp publish_completion({:failed, document}) do
    _ = Topics.broadcast_document_updated(document)
    :failed
  end

  defp publish_completion(result), do: result

  @doc """
  Updates document status to processing.

  Only updates if document is currently in uploading, extracting, or queued state.
  This is safe to call multiple times - it will only update if needed.
  """
  @spec update_document_status_to_processing(Ecto.UUID.t() | Documents.Page.t()) ::
          :ok | {:error, :obsolete_run}
  def update_document_status_to_processing(%Documents.Page{} = page) do
    Run.with_page(page, fn _ -> start_processing(page.document_id) end)
    |> publish_status()
  end

  def update_document_status_to_processing(document_id) do
    start_processing(document_id) |> publish_status()
  end

  defp start_processing(document_id) do
    case Documents.get_document(document_id) do
      %{status: status} = document when status in ["uploading", "extracting", "queued"] ->
        Documents.update_document_status(document, "processing")

      _ ->
        :ok
    end
  end

  defp publish_status({:ok, document}) do
    _ = Topics.broadcast_document_updated(document)
    :ok
  end

  defp publish_status(result), do: result
end
