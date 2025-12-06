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
  alias Doctrans.Processing.{Ollama, PdfExtractor}
  alias Doctrans.Search.EmbeddingWorker

  @max_retries 3

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

        with document when not is_nil(document) <- Documents.get_document(document_id),
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
  # PDF Extraction (runs immediately, not queued)
  # ============================================================================

  defp do_extract_pdf(document_id, pdf_path, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping PDF extraction")
      # Clean up the PDF file
      File.rm(pdf_path)
      :cancelled
    else
      with {:ok, document} <- fetch_document(document_id),
           :ok <- extract_pdf_pages(document, pdf_path) do
        :ok
      else
        {:error, reason} ->
          Logger.error("Failed to extract PDF for document #{document_id}: #{reason}")

          case Documents.get_document(document_id) do
            nil -> :ok
            document -> Documents.update_document_status(document, "error", reason)
          end

          {:error, reason}
      end
    end
  end

  defp extract_pdf_pages(document, pdf_path) do
    Logger.info("Extracting pages from PDF for document #{document.id}")

    # Ensure directories exist
    pages_dir = Documents.ensure_document_dirs!(document.id)

    # Extract pages
    case PdfExtractor.extract_pages(pdf_path, pages_dir) do
      {:ok, page_count} ->
        Logger.info("Extracted #{page_count} pages for document #{document.id}")

        # Update document with page count
        {:ok, document} = Documents.update_document(document, %{total_pages: page_count})

        # Create page records
        page_images = PdfExtractor.list_page_images(pages_dir)

        page_attrs =
          page_images
          |> Enum.with_index(1)
          |> Enum.map(fn {image_path, page_number} ->
            relative_path = Path.relative_to(image_path, Documents.uploads_dir())
            %{page_number: page_number, image_path: relative_path}
          end)

        Documents.create_pages(document, page_attrs)

        # Delete the original PDF to save space
        File.rm(pdf_path)

        # Broadcast update with pages ready
        Documents.broadcast_document_update(document)

        :ok

      {:error, reason} ->
        {:error, "PDF extraction failed: #{reason}"}
    end
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
  # LLM Processing Logic
  # ============================================================================

  defp do_process_llm(document_id, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping LLM processing")
      :ok
    else
      document_id
      |> process_all_pages(cancelled_documents)
      |> handle_llm_result(document_id)
    end
  end

  defp handle_llm_result(:ok, document_id) do
    document = Documents.get_document!(document_id)
    Documents.update_document_status(document, "completed")
    Documents.broadcast_document_update(document)
    :ok
  end

  defp handle_llm_result({:cancelled, _}, document_id) do
    Logger.info("Document #{document_id} LLM processing was cancelled")
    :ok
  end

  defp handle_llm_result({:error, reason}, document_id) do
    Logger.error("Failed to process LLM for document #{document_id}: #{reason}")
    maybe_update_document_error(document_id, reason)
    {:error, reason}
  end

  defp maybe_update_document_error(document_id, reason) do
    case Documents.get_document(document_id) do
      nil -> :ok
      document -> Documents.update_document_status(document, "error", reason)
    end
  end

  defp fetch_document(document_id) do
    case Documents.get_document(document_id) do
      nil -> {:error, "Document not found"}
      document -> {:ok, document}
    end
  end

  defp process_all_pages(document_id, cancelled_documents) do
    process_next_page(document_id, cancelled_documents)
  end

  defp process_next_page(document_id, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      {:cancelled, document_id}
    else
      find_and_process_next_page(document_id, cancelled_documents)
    end
  end

  defp find_and_process_next_page(document_id, cancelled_documents) do
    case Documents.get_next_page_for_extraction(document_id) do
      nil -> find_translation_page(document_id, cancelled_documents)
      page -> process_page_and_continue(page, document_id, cancelled_documents)
    end
  end

  defp find_translation_page(document_id, cancelled_documents) do
    if Documents.all_pages_completed?(document_id) do
      :ok
    else
      case Documents.get_next_page_for_translation(document_id) do
        nil -> :ok
        page -> process_page_and_continue(page, document_id, cancelled_documents)
      end
    end
  end

  defp process_page_and_continue(page, document_id, cancelled_documents) do
    case maybe_extract_page(page) do
      {:error, reason} ->
        {:error, reason}

      updated_page ->
        maybe_translate_and_continue(updated_page, document_id, cancelled_documents)
    end
  end

  defp maybe_extract_page(%{extraction_status: "pending"} = page) do
    case process_page_extraction(page) do
      :ok -> Documents.get_page!(page.id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_extract_page(page), do: page

  defp maybe_translate_and_continue(page, document_id, cancelled_documents) do
    if page.extraction_status == "completed" && page.translation_status == "pending" do
      case process_page_translation(page) do
        :ok -> process_next_page(document_id, cancelled_documents)
        {:error, reason} -> {:error, reason}
      end
    else
      process_next_page(document_id, cancelled_documents)
    end
  end

  defp process_page_extraction(page, retry_count \\ 0) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "processing"})
    Documents.broadcast_page_update(page)

    image_path = Path.join(Documents.uploads_dir(), page.image_path)

    case Ollama.extract_markdown(image_path) do
      {:ok, markdown} ->
        {:ok, page} =
          Documents.update_page_extraction(page, %{
            original_markdown: markdown,
            extraction_status: "completed"
          })

        Documents.broadcast_page_update(page)

        # Generate embedding for semantic search
        EmbeddingWorker.generate_embedding(page.id)

        :ok

      {:error, reason} ->
        if retry_count < @max_retries do
          Logger.warning(
            "Extraction failed for page #{page.page_number}, retrying (#{retry_count + 1}/#{@max_retries})"
          )

          Process.sleep(1_000)
          process_page_extraction(page, retry_count + 1)
        else
          Logger.error(
            "Extraction failed for page #{page.page_number} after #{@max_retries} retries: #{reason}"
          )

          {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "error"})
          Documents.broadcast_page_update(page)
          {:error, "Page #{page.page_number} extraction failed: #{reason}"}
        end
    end
  end

  defp process_page_translation(page, retry_count \\ 0) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Documents.broadcast_page_update(page)

    document = Documents.get_document!(page.document_id)

    case Ollama.translate(page.original_markdown, document.target_language) do
      {:ok, translated} ->
        {:ok, page} =
          Documents.update_page_translation(page, %{
            translated_markdown: translated,
            translation_status: "completed"
          })

        Documents.broadcast_page_update(page)
        :ok

      {:error, reason} ->
        if retry_count < @max_retries do
          Logger.warning(
            "Translation failed for page #{page.page_number}, retrying (#{retry_count + 1}/#{@max_retries})"
          )

          Process.sleep(1_000)
          process_page_translation(page, retry_count + 1)
        else
          Logger.error(
            "Translation failed for page #{page.page_number} after #{@max_retries} retries: #{reason}"
          )

          {:ok, page} = Documents.update_page_translation(page, %{translation_status: "error"})
          Documents.broadcast_page_update(page)
          {:error, "Page #{page.page_number} translation failed: #{reason}"}
        end
    end
  end
end
