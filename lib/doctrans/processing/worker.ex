defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents.

  Handles the processing pipeline:
  1. Extract page images from PDF (runs immediately, not queued)
  2. Extract markdown from each page using Qwen3-VL (queued)
  3. Translate markdown using Qwen3 (queued)

  PDF extraction runs immediately for all documents to make thumbnails
  available quickly. LLM processing is queued to avoid overwhelming Ollama.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Processing.{LlmProcessor, PdfProcessor}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts processing a document from an uploaded PDF.

  PDF extraction happens immediately (not queued) to make thumbnails
  available quickly. LLM processing is queued to run sequentially.
  """
  def process_document(document_id, pdf_path) do
    GenServer.cast(__MODULE__, {:extract_pdf, document_id, pdf_path})
  end

  @doc """
  Cancels processing for a specific document.
  """
  def cancel_document(document_id) do
    GenServer.cast(__MODULE__, {:cancel_document, document_id})
  end

  @doc """
  Returns the current processing status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      current_document_id: nil,
      cancelled_documents: MapSet.new(),
      llm_task_ref: nil,
      extraction_tasks: %{},
      queue: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:extract_pdf, document_id, pdf_path}, state) do
    # PDF extraction runs immediately (not queued)
    Logger.info("Starting PDF extraction for document #{document_id}")

    # Update status to extracting immediately so UI shows progress
    case Documents.get_document(document_id) do
      nil ->
        {:noreply, state}

      document ->
        {:ok, document} = Documents.update_document_status(document, "extracting")
        Documents.broadcast_document_update(document)

        task =
          Task.Supervisor.async_nolink(
            Doctrans.TaskSupervisor,
            fn -> do_extract_pdf(document_id, pdf_path, state.cancelled_documents) end
          )

        extraction_tasks = Map.put(state.extraction_tasks, task.ref, document_id)
        {:noreply, %{state | extraction_tasks: extraction_tasks}}
    end
  end

  @impl true
  def handle_cast({:queue_for_llm, document_id}, state) do
    if MapSet.member?(state.cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, not queueing for LLM")
      {:noreply, state}
    else
      if state.current_document_id == nil do
        # Not busy, start LLM processing immediately
        {:noreply, start_llm_processing(state, document_id)}
      else
        # Busy, add to queue and update document status
        Logger.info("Document #{document_id} queued for LLM processing")

        with %{} = document <- Documents.get_document(document_id),
             {:ok, document} <- Documents.update_document_status(document, "queued") do
          Documents.broadcast_document_update(document)
        end

        queue = :queue.in(document_id, state.queue)
        {:noreply, %{state | queue: queue}}
      end
    end
  end

  @impl true
  def handle_cast({:cancel_document, document_id}, state) do
    Logger.info("Cancelling document #{document_id}")
    cancelled_documents = MapSet.put(state.cancelled_documents, document_id)
    {:noreply, %{state | cancelled_documents: cancelled_documents}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      current_document_id: state.current_document_id,
      queue_length: :queue.len(state.queue),
      extracting_count: map_size(state.extraction_tasks)
    }

    {:reply, status, state}
  end

  # Handle PDF extraction task completion
  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.extraction_tasks, ref) do
    Process.demonitor(ref, [:flush])
    {document_id, extraction_tasks} = Map.pop(state.extraction_tasks, ref)

    case result do
      :ok ->
        Logger.info("PDF extraction completed for document #{document_id}, queueing for LLM")
        # Queue for LLM processing
        GenServer.cast(self(), {:queue_for_llm, document_id})

      :cancelled ->
        Logger.info("PDF extraction was cancelled for document #{document_id}")

      {:error, reason} ->
        Logger.error("PDF extraction failed for document #{document_id}: #{reason}")
    end

    {:noreply, %{state | extraction_tasks: extraction_tasks}}
  end

  # Handle LLM task completion
  @impl true
  def handle_info({ref, result}, %{llm_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Logger.info("Document #{state.current_document_id} LLM processing completed")

      {:error, reason} ->
        Logger.error("Document #{state.current_document_id} LLM processing failed: #{reason}")
    end

    state = %{state | current_document_id: nil, llm_task_ref: nil}
    {:noreply, maybe_process_next(state)}
  end

  # Handle extraction task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.extraction_tasks, ref) do
    {document_id, extraction_tasks} = Map.pop(state.extraction_tasks, ref)
    Logger.error("PDF extraction task crashed for document #{document_id}: #{inspect(reason)}")

    case Documents.get_document(document_id) do
      nil -> :ok
      document -> Documents.update_document_status(document, "error", "Extraction crashed")
    end

    {:noreply, %{state | extraction_tasks: extraction_tasks}}
  end

  # Handle LLM task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{llm_task_ref: ref} = state) do
    Logger.error("LLM processing task crashed: #{inspect(reason)}")

    if state.current_document_id do
      case Documents.get_document(state.current_document_id) do
        nil -> :ok
        document -> Documents.update_document_status(document, "error", "LLM processing crashed")
      end
    end

    state = %{state | current_document_id: nil, llm_task_ref: nil}
    {:noreply, maybe_process_next(state)}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # PDF Extraction (delegated to PdfProcessor)
  # ============================================================================

  defp do_extract_pdf(document_id, pdf_path, cancelled_documents) do
    PdfProcessor.extract_document(document_id, pdf_path, cancelled_documents)
  end

  # ============================================================================
  # LLM Processing Queue
  # ============================================================================

  defp start_llm_processing(state, document_id) do
    Logger.info("Starting LLM processing for document #{document_id}")

    # Update status to processing
    case Documents.get_document(document_id) do
      nil ->
        state

      document ->
        {:ok, document} = Documents.update_document_status(document, "processing")
        Documents.broadcast_document_update(document)

        task =
          Task.Supervisor.async_nolink(
            Doctrans.TaskSupervisor,
            fn -> do_process_llm(document_id, state.cancelled_documents) end
          )

        %{state | current_document_id: document_id, llm_task_ref: task.ref}
    end
  end

  defp maybe_process_next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, document_id}, queue} ->
        if MapSet.member?(state.cancelled_documents, document_id) do
          maybe_process_next(%{state | queue: queue})
        else
          start_llm_processing(%{state | queue: queue}, document_id)
        end
    end
  end

  # ============================================================================
  # LLM Processing Logic (delegated to LlmProcessor)
  # ============================================================================

  defp do_process_llm(document_id, cancelled_documents) do
    LlmProcessor.process_document(document_id, cancelled_documents)
  end
end
