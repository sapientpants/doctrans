defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents.

  Handles the processing pipeline:
  1. Extract page images from PDF (runs immediately, not queued)
  2. Queue pages for LLM processing as they're extracted
  3. Process pages sequentially: extract markdown then translate

  PDF extraction runs immediately for all documents to make thumbnails
  available quickly. LLM processing uses a two-level queue:
  - Document queue: documents wait for their turn
  - Page queue: pages of the active document are processed sequentially

  This ensures:
  - Processing starts as soon as first page is available
  - Documents are processed one at a time (no mixing pages from different docs)
  - Individual pages can be reprocessed
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
  Starts PDF extraction for a document.

  PDF extraction happens immediately (not queued) to make thumbnails
  available quickly. Pages are queued for LLM processing as they're extracted.
  """
  def process_document(document_id, pdf_path) do
    GenServer.cast(__MODULE__, {:extract_pdf, document_id, pdf_path})
  end

  @doc """
  Queues a page for LLM processing.

  If the page's document is currently being processed, the page is added
  to the active page queue. Otherwise, the document is added to the
  document queue (if not already there).
  """
  def queue_page(page_id) do
    GenServer.cast(__MODULE__, {:queue_page, page_id})
  end

  @doc """
  Cancels processing for a specific document.
  All pages of the document will be skipped.
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
      # Currently processing document
      current_document_id: nil,
      # Currently processing page within that document
      current_page_id: nil,
      # Pages queued for the current document
      page_queue: :queue.new(),
      # Documents waiting to be processed
      document_queue: :queue.new(),
      # Cancelled document IDs
      cancelled_documents: MapSet.new(),
      # Task ref for LLM processing
      llm_task_ref: nil,
      # Extraction tasks in progress
      extraction_tasks: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:extract_pdf, document_id, pdf_path}, state) do
    Logger.info("Starting PDF extraction for document #{document_id}")

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
  def handle_cast({:queue_page, page_id}, state) do
    case Documents.get_page(page_id) do
      nil ->
        Logger.warning("Page #{page_id} not found, skipping queue")
        {:noreply, state}

      page ->
        if MapSet.member?(state.cancelled_documents, page.document_id) do
          Logger.info("Document #{page.document_id} was cancelled, not queueing page #{page_id}")
          {:noreply, state}
        else
          {:noreply, handle_page_queue(state, page)}
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
      current_page_id: state.current_page_id,
      page_queue_length: :queue.len(state.page_queue),
      document_queue_length: :queue.len(state.document_queue),
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
        Logger.info("PDF extraction completed for document #{document_id}")

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
        Logger.info("Page #{state.current_page_id} LLM processing completed")

      {:error, reason} ->
        Logger.error("Page #{state.current_page_id} LLM processing failed: #{reason}")
    end

    state = %{state | current_page_id: nil, llm_task_ref: nil}
    {:noreply, process_next_page(state)}
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
    Logger.error(
      "LLM processing task crashed for page #{state.current_page_id}: #{inspect(reason)}"
    )

    if state.current_page_id do
      case Documents.get_page(state.current_page_id) do
        nil -> :ok
        page -> Documents.update_page_extraction(page, %{extraction_status: "error"})
      end
    end

    state = %{state | current_page_id: nil, llm_task_ref: nil}
    {:noreply, process_next_page(state)}
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
  # Page Queue Management
  # ============================================================================

  defp handle_page_queue(state, page) do
    cond do
      # This page's document is currently being processed
      state.current_document_id == page.document_id ->
        if state.current_page_id == nil do
          # Not busy, start processing immediately
          start_page_processing(state, page)
        else
          # Busy, add to page queue
          Logger.info("Page #{page.id} added to queue for active document #{page.document_id}")
          page_queue = :queue.in(page.id, state.page_queue)
          %{state | page_queue: page_queue}
        end

      # No document is currently processing
      state.current_document_id == nil ->
        # Start processing this document
        Logger.info("Starting processing for document #{page.document_id}")
        update_document_status_to_processing(page.document_id)
        start_page_processing(%{state | current_document_id: page.document_id}, page)

      # Another document is processing, queue this document
      true ->
        queue_document_if_not_queued(state, page)
    end
  end

  defp queue_document_if_not_queued(state, page) do
    document_id = page.document_id
    queued_docs = :queue.to_list(state.document_queue)

    if document_id in queued_docs do
      # Document already in queue, nothing to do
      state
    else
      Logger.info("Document #{document_id} added to document queue")
      update_document_status_to_queued(document_id)
      document_queue = :queue.in(document_id, state.document_queue)
      %{state | document_queue: document_queue}
    end
  end

  defp update_document_status_to_processing(document_id) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        if document.status in ["extracting", "queued"] do
          {:ok, document} = Documents.update_document_status(document, "processing")
          Documents.broadcast_document_update(document)
        end
    end
  end

  defp update_document_status_to_queued(document_id) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        if document.status == "extracting" do
          {:ok, document} = Documents.update_document_status(document, "queued")
          Documents.broadcast_document_update(document)
        end
    end
  end

  defp start_page_processing(state, page) do
    Logger.info("Starting LLM processing for page #{page.id} (doc #{page.document_id})")

    task =
      Task.Supervisor.async_nolink(
        Doctrans.TaskSupervisor,
        fn -> do_process_page(page.id, state.cancelled_documents) end
      )

    %{state | current_page_id: page.id, llm_task_ref: task.ref}
  end

  defp process_next_page(state) do
    case :queue.out(state.page_queue) do
      {:empty, _queue} ->
        # No more pages for this document, check if document is complete
        check_document_completion(state)

      {{:value, page_id}, page_queue} ->
        case Documents.get_page(page_id) do
          nil ->
            # Page was deleted, skip
            process_next_page(%{state | page_queue: page_queue})

          page ->
            if MapSet.member?(state.cancelled_documents, page.document_id) do
              process_next_page(%{state | page_queue: page_queue})
            else
              start_page_processing(%{state | page_queue: page_queue}, page)
            end
        end
    end
  end

  defp check_document_completion(state) do
    if state.current_document_id do
      document_id = state.current_document_id

      Logger.debug(
        "Checking document completion for #{document_id}, page_queue_len=#{:queue.len(state.page_queue)}"
      )

      if Documents.all_pages_completed?(document_id) do
        Logger.info("Document #{document_id} fully processed")
        mark_document_completed(document_id)
        start_next_document(%{state | current_document_id: nil})
      else
        Logger.debug("Document #{document_id} not yet complete, waiting for more pages")
        # More pages might come from extraction, wait
        state
      end
    else
      start_next_document(state)
    end
  end

  defp mark_document_completed(document_id) do
    case Documents.get_document(document_id) do
      nil ->
        :ok

      document ->
        {:ok, document} = Documents.update_document_status(document, "completed")
        Documents.broadcast_document_update(document)
    end
  end

  defp start_next_document(state) do
    case :queue.out(state.document_queue) do
      {:empty, _queue} ->
        state

      {{:value, document_id}, document_queue} ->
        if MapSet.member?(state.cancelled_documents, document_id) do
          start_next_document(%{state | document_queue: document_queue})
        else
          Logger.info("Starting processing for queued document #{document_id}")
          update_document_status_to_processing(document_id)

          # Get all pending pages for this document and queue them
          state = %{state | current_document_id: document_id, document_queue: document_queue}
          queue_pending_pages_for_document(state, document_id)
        end
    end
  end

  defp queue_pending_pages_for_document(state, document_id) do
    pages = Documents.list_pages(document_id)

    pending_pages =
      pages
      |> Enum.filter(&(&1.extraction_status == "pending" || &1.translation_status == "pending"))
      |> Enum.sort_by(& &1.page_number)

    case pending_pages do
      [] ->
        # No pending pages, mark complete and move on
        mark_document_completed(document_id)
        start_next_document(%{state | current_document_id: nil})

      [first | rest] ->
        # Queue remaining pages, start first
        page_queue =
          Enum.reduce(rest, :queue.new(), fn page, queue ->
            :queue.in(page.id, queue)
          end)

        state = %{state | page_queue: page_queue}
        start_page_processing(state, first)
    end
  end

  # ============================================================================
  # Page Processing Logic (delegated to LlmProcessor)
  # ============================================================================

  defp do_process_page(page_id, cancelled_documents) do
    LlmProcessor.process_page(page_id, cancelled_documents)
  end
end
