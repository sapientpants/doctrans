defmodule Doctrans.Processing.DocumentOrchestrator do
  @moduledoc """
  Orchestrates document-level processing logic.

  Handles:
  - Document completion checking
  - Document status transitions
  - Recovery of incomplete documents
  - Document lifecycle management
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Run

  @doc """
  Resolves the document state from its pages and applies terminal transitions.

  Only fully successful pages complete a document. A document whose pages have
  all settled with at least one failure becomes an error, unless a failed page
  still has a pending retry that may yet succeed (`:retrying`).
  """
  @spec check_document_completion(
          Uniq.UUID.t()
          | Documents.Page.t()
          | Documents.Document.t()
          | nil
        ) ::
          :completed | :failed | :retrying | :incomplete | {:error, :obsolete_run}
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
      Run.retry_pending?(document.id) ->
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
    _ = Topics.broadcast_document_update(document)
    :completed
  end

  defp publish_completion({:failed, document}) do
    _ = Topics.broadcast_document_update(document)
    :failed
  end

  defp publish_completion(result), do: result

  @doc """
  Gets the current status of a document.
  """
  @spec get_document_status(Uniq.UUID.t()) :: String.t() | nil
  def get_document_status(document_id) do
    case Documents.get_document(document_id) do
      nil -> nil
      document -> document.status
    end
  end

  @doc """
  Marks a document as completed.
  """
  @spec mark_document_completed(Uniq.UUID.t()) :: :ok
  def mark_document_completed(document_id) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        {:ok, document} = Documents.update_document_status(document, "completed")
        _ = Topics.broadcast_document_update(document)
        :ok
    end
  end

  @doc """
  Recovers incomplete documents on startup.
  """
  @spec recover_incomplete_documents() :: [Doctrans.Documents.Document.t()] | []
  def recover_incomplete_documents do
    # Find documents that need processing (processing or queued status)
    incomplete_docs = Documents.list_incomplete_documents()

    case incomplete_docs do
      [] ->
        Logger.info("No incomplete documents to recover")
        []

      docs ->
        Logger.info("Found #{length(docs)} incomplete documents to recover")
        docs
    end
  end

  @doc """
  Updates document status to processing.

  Only updates if document is currently in uploading, extracting, or queued state.
  This is safe to call multiple times - it will only update if needed.
  """
  @spec update_document_status_to_processing(Uniq.UUID.t() | Documents.Page.t()) ::
          :ok | {:error, :obsolete_run}
  def update_document_status_to_processing(%Documents.Page{} = page) do
    Run.with_page(page, fn _ ->
      update_document_status(page.document_id, "processing", ["uploading", "extracting", "queued"])
    end)
    |> publish_status()
  end

  def update_document_status_to_processing(document_id) do
    update_document_status(document_id, "processing", ["uploading", "extracting", "queued"])
    |> publish_status()
  end

  @doc """
  Updates document status to queued.
  """
  @spec update_document_status_to_queued(Uniq.UUID.t()) :: :ok
  def update_document_status_to_queued(document_id) do
    update_document_status(document_id, "queued", ["extracting"])
    |> publish_status()
  end

  # Private functions

  defp update_document_status(document_id, new_status, valid_from) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        if document.status in valid_from do
          Documents.update_document_status(document, new_status)
        else
          :ok
        end
    end
  end

  defp publish_status({:ok, document}) do
    _ = Topics.broadcast_document_update(document)
    :ok
  end

  defp publish_status(result), do: result

  @doc """
  Starts document processing.
  """
  @spec start_document_processing(Doctrans.Documents.Document.t()) ::
          {:ok, :processing_started} | {:error, atom()}
  def start_document_processing(document) do
    # First check if document exists
    case Documents.get_document(document.id) do
      nil ->
        {:error, :document_not_found}

      existing_doc ->
        # Use the existing document from database
        case existing_doc.status do
          "queued" ->
            :ok = update_document_status_to_processing(document.id)
            {:ok, :processing_started}

          "processing" ->
            {:error, :already_processing}

          "completed" ->
            {:error, :already_completed}

          "extracting" ->
            :ok = update_document_status_to_processing(document.id)
            {:ok, :processing_started}

          _ ->
            {:error, :invalid_status}
        end
    end
  end

  @doc """
  Completes document processing.
  """
  @spec complete_document_processing(Doctrans.Documents.Document.t()) ::
          {:ok, :completed} | {:error, atom()}
  def complete_document_processing(document) do
    # First check if document exists
    case Documents.get_document(document.id) do
      nil ->
        {:error, :document_not_found}

      existing_doc ->
        # Use the existing document from database
        case existing_doc.status do
          "processing" ->
            mark_document_completed(document.id)
            {:ok, :completed}

          "completed" ->
            {:error, :already_completed}

          _ ->
            {:error, :invalid_status}
        end
    end
  end

  @doc """
  Fails document processing with an error message.
  """
  @spec fail_document_processing(
          Doctrans.Documents.Document.t(),
          Doctrans.Errors.reason() | String.t()
        ) ::
          {:ok, :failed} | {:error, atom()}
  def fail_document_processing(document, error_message) do
    # First check if document exists
    case Documents.get_document(document.id) do
      nil ->
        {:error, :document_not_found}

      existing_doc ->
        # Use the existing document from database
        case existing_doc.status do
          "processing" ->
            Documents.update_document_status(existing_doc, "error", error_message)
            {:ok, :failed}

          _ ->
            {:error, :invalid_status}
        end
    end
  end

  @doc """
  Resets document for retry.
  """
  @spec reset_document_for_retry(Doctrans.Documents.Document.t()) ::
          {:ok, :reset} | {:error, atom()}
  def reset_document_for_retry(document) do
    # First check if document exists
    case Documents.get_document(document.id) do
      nil ->
        {:error, :document_not_found}

      existing_doc ->
        # Use the existing document from database
        case existing_doc.status do
          "completed" ->
            {:error, :cannot_reset_completed}

          _ ->
            Documents.update_document_status(existing_doc, "queued")
            {:ok, :reset}
        end
    end
  end

  @doc """
  Checks if a document can be processed.
  """
  @spec can_process_document?(Doctrans.Documents.Document.t()) :: boolean()
  def can_process_document?(document) do
    document.status in ["queued", "extracting"]
  end
end
