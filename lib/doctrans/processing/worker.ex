defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing books.

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
  Starts processing a book from an uploaded PDF.

  The PDF will be extracted, then each page will be processed for
  markdown extraction and translation.
  """
  def process_book(book_id, pdf_path) do
    GenServer.cast(__MODULE__, {:process_book, book_id, pdf_path})
  end

  @doc """
  Cancels processing for a specific book.
  """
  def cancel_book(book_id) do
    GenServer.cast(__MODULE__, {:cancel_book, book_id})
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
      current_book_id: nil,
      cancelled_books: MapSet.new(),
      task_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_book, book_id, pdf_path}, state) do
    Logger.info("Starting to process book #{book_id}")

    # Start the processing task
    task =
      Task.Supervisor.async_nolink(
        Doctrans.TaskSupervisor,
        fn -> do_process_book(book_id, pdf_path, state.cancelled_books) end
      )

    {:noreply, %{state | current_book_id: book_id, task_ref: task.ref}}
  end

  @impl true
  def handle_cast({:cancel_book, book_id}, state) do
    Logger.info("Cancelling book #{book_id}")
    cancelled_books = MapSet.put(state.cancelled_books, book_id)
    {:noreply, %{state | cancelled_books: cancelled_books}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{current_book_id: state.current_book_id}, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    # Task completed, clean up the reference
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Logger.info("Book #{state.current_book_id} processing completed successfully")

      {:error, reason} ->
        Logger.error("Book #{state.current_book_id} processing failed: #{reason}")
    end

    {:noreply, %{state | current_book_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("Book processing task crashed: #{inspect(reason)}")

    # Mark the book as errored
    if state.current_book_id do
      case Documents.get_book(state.current_book_id) do
        nil ->
          :ok

        book ->
          Documents.update_book_status(book, "error", "Processing crashed: #{inspect(reason)}")
      end
    end

    {:noreply, %{state | current_book_id: nil, task_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Processing Logic
  # ============================================================================

  defp do_process_book(book_id, pdf_path, cancelled_books) do
    if MapSet.member?(cancelled_books, book_id) do
      Logger.info("Book #{book_id} was cancelled, skipping")
      :ok
    else
      with {:ok, book} <- fetch_book(book_id),
           :ok <- extract_pdf_pages(book, pdf_path, cancelled_books),
           :ok <- process_all_pages(book_id, cancelled_books) do
        # Mark book as completed
        book = Documents.get_book!(book_id)
        Documents.update_book_status(book, "completed")
        Documents.broadcast_book_update(book)
        :ok
      else
        {:cancelled, _} ->
          Logger.info("Book #{book_id} processing was cancelled")
          :ok

        {:error, reason} ->
          Logger.error("Failed to process book #{book_id}: #{reason}")

          case Documents.get_book(book_id) do
            nil -> :ok
            book -> Documents.update_book_status(book, "error", reason)
          end

          {:error, reason}
      end
    end
  end

  defp fetch_book(book_id) do
    case Documents.get_book(book_id) do
      nil -> {:error, "Book not found"}
      book -> {:ok, book}
    end
  end

  defp extract_pdf_pages(book, pdf_path, cancelled_books) do
    if MapSet.member?(cancelled_books, book.id) do
      {:cancelled, book.id}
    else
      Logger.info("Extracting pages from PDF for book #{book.id}")

      # Update status to extracting
      {:ok, book} = Documents.update_book_status(book, "extracting")
      Documents.broadcast_book_update(book)

      # Ensure directories exist
      pages_dir = Documents.ensure_book_dirs!(book.id)

      # Extract pages
      case PdfExtractor.extract_pages(pdf_path, pages_dir) do
        {:ok, page_count} ->
          Logger.info("Extracted #{page_count} pages for book #{book.id}")

          # Update book with page count
          {:ok, book} = Documents.update_book(book, %{total_pages: page_count})

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

          Documents.create_pages(book, page_attrs)

          # Delete the original PDF to save space
          File.rm(pdf_path)

          # Update status to processing
          {:ok, book} = Documents.update_book_status(book, "processing")
          Documents.broadcast_book_update(book)

          :ok

        {:error, reason} ->
          {:error, "PDF extraction failed: #{reason}"}
      end
    end
  end

  defp process_all_pages(book_id, cancelled_books) do
    # Process each page completely (extraction + translation) before moving to the next
    process_next_page(book_id, cancelled_books)
  end

  defp process_next_page(book_id, cancelled_books) do
    if MapSet.member?(cancelled_books, book_id) do
      {:cancelled, book_id}
    else
      # First check if there's a page that needs extraction
      case Documents.get_next_page_for_extraction(book_id) do
        nil ->
          # No more pages to extract, check if all translations are done
          if Documents.all_pages_completed?(book_id) do
            :ok
          else
            # There might be a page with completed extraction but pending translation
            case Documents.get_next_page_for_translation(book_id) do
              nil -> :ok
              page -> process_page_and_continue(page, book_id, cancelled_books)
            end
          end

        page ->
          process_page_and_continue(page, book_id, cancelled_books)
      end
    end
  end

  defp process_page_and_continue(page, book_id, cancelled_books) do
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
            :ok -> process_next_page(book_id, cancelled_books)
            {:error, reason} -> {:error, reason}
          end
        else
          # Move to next page
          process_next_page(book_id, cancelled_books)
        end
    end
  end

  defp process_page_extraction(page, retry_count \\ 0) do
    Logger.info("Extracting markdown for page #{page.page_number} of book #{page.book_id}")

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
    Logger.info("Translating page #{page.page_number} of book #{page.book_id}")

    # Mark as processing
    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Documents.broadcast_page_update(page)

    # Get book for language info
    book = Documents.get_book!(page.book_id)

    case Ollama.translate(page.original_markdown, book.source_language, book.target_language) do
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
