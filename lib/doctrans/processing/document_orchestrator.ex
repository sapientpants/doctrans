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

  @doc """
  Checks if the current document is complete and handles completion.
  """
  @spec check_document_completion(Uniq.UUID.t() | nil) :: :completed | :incomplete
  def check_document_completion(nil), do: :incomplete

  def check_document_completion(document_id) do
    Logger.debug("Checking document completion for #{document_id}")

    if Documents.all_pages_completed?(document_id) do
      Logger.info("Document #{document_id} fully processed")
      mark_document_completed(document_id)
      :completed
    else
      Logger.debug("Document #{document_id} not yet complete, waiting for more pages")
      :incomplete
    end
  end

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
        Documents.broadcast_document_update(document)
        :ok
    end
  end

  @doc """
  Recovers incomplete documents on startup.
  """
  @spec recover_incomplete_documents() :: [Doctrans.Documents.t()] | []
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
  @spec update_document_status_to_processing(Uniq.UUID.t()) :: :ok
  def update_document_status_to_processing(document_id) do
    update_document_status(document_id, "processing", ["uploading", "extracting", "queued"])
  end

  @doc """
  Updates document status to queued.
  """
  @spec update_document_status_to_queued(Uniq.UUID.t()) :: :ok
  def update_document_status_to_queued(document_id) do
    update_document_status(document_id, "queued", ["extracting"])
  end

  # Private functions

  defp update_document_status(document_id, new_status, valid_from) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        if document.status in valid_from do
          {:ok, document} = Documents.update_document_status(document, new_status)
          Documents.broadcast_document_update(document)
        end

        :ok
    end
  end

  @doc """
  Starts document processing.
  """
  @spec start_document_processing(Doctrans.Documents.t()) ::
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
            update_document_status_to_processing(document.id)
            {:ok, :processing_started}

          "processing" ->
            {:error, :already_processing}

          "completed" ->
            {:error, :already_completed}

          "extracting" ->
            update_document_status_to_processing(document.id)
            {:ok, :processing_started}

          _ ->
            {:error, :invalid_status}
        end
    end
  end

  @doc """
  Completes document processing.
  """
  @spec complete_document_processing(Doctrans.Documents.t()) ::
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
  @spec fail_document_processing(Doctrans.Documents.t(), String.t()) ::
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
  @spec reset_document_for_retry(Doctrans.Documents.t()) ::
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
  @spec can_process_document?(Doctrans.Documents.t()) :: boolean()
  def can_process_document?(document) do
    document.status in ["queued", "extracting"]
  end
end
