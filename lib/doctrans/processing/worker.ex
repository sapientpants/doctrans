defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents.

  Handles the processing pipeline:
  1. Extract page images from PDF
  2. Extract markdown from each page using Qwen3-VL
  3. Translate markdown using Qwen3

  Processing is done sequentially to avoid overwhelming Ollama.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Processing.{PdfExtractor, Ollama}

  @max_retries 3

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts processing a document from an uploaded PDF.

  The PDF will be extracted, then each page will be processed for
  markdown extraction and translation.
  """
  def process_document(document_id, pdf_path) do
    GenServer.cast(__MODULE__, {:process_document, document_id, pdf_path})
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
      task_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_document, document_id, pdf_path}, state) do
    Logger.info("Starting to process document #{document_id}")

    # Start the processing task
    task =
      Task.Supervisor.async_nolink(
        Doctrans.TaskSupervisor,
        fn -> do_process_document(document_id, pdf_path, state.cancelled_documents) end
      )

    {:noreply, %{state | current_document_id: document_id, task_ref: task.ref}}
  end

  @impl true
  def handle_cast({:cancel_document, document_id}, state) do
    Logger.info("Cancelling document #{document_id}")
    cancelled_documents = MapSet.put(state.cancelled_documents, document_id)
    {:noreply, %{state | cancelled_documents: cancelled_documents}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{current_document_id: state.current_document_id}, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    # Task completed, clean up the reference
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Logger.info("Document #{state.current_document_id} processing completed successfully")

      {:error, reason} ->
        Logger.error("Document #{state.current_document_id} processing failed: #{reason}")
    end

    {:noreply, %{state | current_document_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("Document processing task crashed: #{inspect(reason)}")

    # Mark the document as errored
    if state.current_document_id do
      case Documents.get_document(state.current_document_id) do
        nil ->
          :ok

        document ->
          Documents.update_document_status(
            document,
            "error",
            "Processing crashed: #{inspect(reason)}"
          )
      end
    end

    {:noreply, %{state | current_document_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Processing Logic
  # ============================================================================

  defp do_process_document(document_id, pdf_path, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      Logger.info("Document #{document_id} was cancelled, skipping")
      :ok
    else
      with {:ok, document} <- fetch_document(document_id),
           :ok <- extract_pdf_pages(document, pdf_path, cancelled_documents),
           :ok <- process_all_pages(document_id, cancelled_documents) do
        # Mark document as completed
        document = Documents.get_document!(document_id)
        Documents.update_document_status(document, "completed")
        Documents.broadcast_document_update(document)
        :ok
      else
        {:cancelled, _} ->
          Logger.info("Document #{document_id} processing was cancelled")
          :ok

        {:error, reason} ->
          Logger.error("Failed to process document #{document_id}: #{reason}")

          case Documents.get_document(document_id) do
            nil -> :ok
            document -> Documents.update_document_status(document, "error", reason)
          end

          {:error, reason}
      end
    end
  end

  defp fetch_document(document_id) do
    case Documents.get_document(document_id) do
      nil -> {:error, "Document not found"}
      document -> {:ok, document}
    end
  end

  defp extract_pdf_pages(document, pdf_path, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document.id) do
      {:cancelled, document.id}
    else
      Logger.info("Extracting pages from PDF for document #{document.id}")

      # Update status to extracting
      {:ok, document} = Documents.update_document_status(document, "extracting")
      Documents.broadcast_document_update(document)

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
              # Store relative path from uploads dir
              relative_path =
                Path.relative_to(image_path, Documents.uploads_dir())

              %{page_number: page_number, image_path: relative_path}
            end)

          Documents.create_pages(document, page_attrs)

          # Delete the original PDF to save space
          File.rm(pdf_path)

          # Update status to processing
          {:ok, document} = Documents.update_document_status(document, "processing")
          Documents.broadcast_document_update(document)

          :ok

        {:error, reason} ->
          {:error, "PDF extraction failed: #{reason}"}
      end
    end
  end

  defp process_all_pages(document_id, cancelled_documents) do
    # Process each page completely (extraction + translation) before moving to the next
    process_next_page(document_id, cancelled_documents)
  end

  defp process_next_page(document_id, cancelled_documents) do
    if MapSet.member?(cancelled_documents, document_id) do
      {:cancelled, document_id}
    else
      # First check if there's a page that needs extraction
      case Documents.get_next_page_for_extraction(document_id) do
        nil ->
          # No more pages to extract, check if all translations are done
          if Documents.all_pages_completed?(document_id) do
            :ok
          else
            # There might be a page with completed extraction but pending translation
            case Documents.get_next_page_for_translation(document_id) do
              nil -> :ok
              page -> process_page_and_continue(page, document_id, cancelled_documents)
            end
          end

        page ->
          process_page_and_continue(page, document_id, cancelled_documents)
      end
    end
  end

  defp process_page_and_continue(page, document_id, cancelled_documents) do
    # Process extraction if needed
    page =
      if page.extraction_status == "pending" do
        case process_page_extraction(page) do
          :ok -> Documents.get_page!(page.id)
          {:error, reason} -> {:error, reason}
        end
      else
        page
      end

    case page do
      {:error, reason} ->
        {:error, reason}

      page ->
        # Process translation if extraction succeeded
        if page.extraction_status == "completed" && page.translation_status == "pending" do
          case process_page_translation(page) do
            :ok -> process_next_page(document_id, cancelled_documents)
            {:error, reason} -> {:error, reason}
          end
        else
          # Move to next page
          process_next_page(document_id, cancelled_documents)
        end
    end
  end

  defp process_page_extraction(page, retry_count \\ 0) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    # Mark as processing
    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "processing"})
    Documents.broadcast_page_update(page)

    # Get the full image path
    image_path = Path.join(Documents.uploads_dir(), page.image_path)

    case Ollama.extract_markdown(image_path) do
      {:ok, markdown} ->
        {:ok, page} =
          Documents.update_page_extraction(page, %{
            original_markdown: markdown,
            extraction_status: "completed"
          })

        Documents.broadcast_page_update(page)
        :ok

      {:error, reason} ->
        if retry_count < @max_retries do
          Logger.warning(
            "Extraction failed for page #{page.page_number}, retrying (#{retry_count + 1}/#{@max_retries})"
          )

          # Small delay before retry
          Process.sleep(1_000)
          process_page_extraction(page, retry_count + 1)
        else
          Logger.error(
            "Extraction failed for page #{page.page_number} after #{@max_retries} retries: #{reason}"
          )

          {:ok, page} =
            Documents.update_page_extraction(page, %{extraction_status: "error"})

          Documents.broadcast_page_update(page)
          {:error, "Page #{page.page_number} extraction failed: #{reason}"}
        end
    end
  end

  defp process_page_translation(page, retry_count \\ 0) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    # Mark as processing
    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Documents.broadcast_page_update(page)

    # Get document for language info
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

          {:ok, page} =
            Documents.update_page_translation(page, %{translation_status: "error"})

          Documents.broadcast_page_update(page)
          {:error, "Page #{page.page_number} translation failed: #{reason}"}
        end
    end
  end
end
