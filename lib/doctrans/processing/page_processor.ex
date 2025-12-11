defmodule Doctrans.Processing.PageProcessor do
  @moduledoc """
  Handles individual page processing logic.

  Manages:
  - Page processing task execution
  - Timeout handling
  - Task lifecycle management
  - Error handling and recovery
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Processing.LlmProcessor

  # Default task timeout: 6 minutes (slightly longer than Ollama timeout)
  @default_task_timeout_ms 360_000

  @type processing_state :: %{
          current_page_id: Uniq.UUID.t() | nil,
          llm_task_ref: reference() | nil,
          llm_timeout_ref: reference() | nil
        }

  @doc """
  Creates a new processing state.
  """
  @spec new_state() :: processing_state()
  def new_state do
    %{
      current_page_id: nil,
      llm_task_ref: nil,
      llm_timeout_ref: nil
    }
  end

  @doc """
  Starts processing a page with the given options.
  """
  @spec start_page_processing(
          processing_state(),
          Doctrans.Documents.Page.t(),
          MapSet.t(Uniq.UUID.t()),
          keyword()
        ) ::
          processing_state()
  def start_page_processing(state, page, cancelled_documents, opts) do
    Logger.info("Starting LLM processing for page #{page.id} (doc #{page.document_id})")

    task =
      Task.Supervisor.async_nolink(
        Doctrans.TaskSupervisor,
        fn -> do_process_page(page.id, cancelled_documents, opts) end
      )

    # Schedule a timeout to prevent indefinitely stuck tasks
    timeout_ms = task_timeout_ms()
    timeout_ref = Process.send_after(self(), {:llm_timeout, task.ref}, timeout_ms)

    %{
      state
      | current_page_id: page.id,
        llm_task_ref: task.ref,
        llm_timeout_ref: timeout_ref
    }
  end

  @doc """
  Handles successful task completion.
  """
  @spec handle_task_success(processing_state()) :: processing_state()
  def handle_task_success(state) do
    if state.current_page_id do
      Logger.info("Page #{state.current_page_id} LLM processing completed")
    end

    clear_task_state(state)
  end

  @doc """
  Handles task failure.
  """
  @spec handle_task_failure(processing_state(), any()) :: processing_state()
  def handle_task_failure(state, reason) do
    if state.current_page_id do
      Logger.error("Page #{state.current_page_id} LLM processing failed: #{reason}")
      mark_page_error(state.current_page_id)
    end

    clear_task_state(state)
  end

  @doc """
  Handles task crash.
  """
  @spec handle_task_crash(processing_state(), any()) :: processing_state()
  def handle_task_crash(state, reason) do
    if state.current_page_id do
      Logger.error(
        "LLM processing task crashed for page #{state.current_page_id}: #{inspect(reason)}"
      )

      mark_page_error(state.current_page_id)
    end

    clear_task_state(state)
  end

  @doc """
  Handles task timeout.
  """
  @spec handle_task_timeout(processing_state()) :: processing_state()
  def handle_task_timeout(state) do
    if state.current_page_id do
      Logger.error("LLM processing task timed out for page #{state.current_page_id}")

      :telemetry.execute(
        [:doctrans, :processing, :timeout],
        %{count: 1},
        %{page_id: state.current_page_id}
      )

      mark_page_error(state.current_page_id)
    end

    clear_task_state(state)
  end

  @doc """
  Checks if the task reference matches the current processing task.
  """
  @spec matches_current_task?(processing_state(), reference()) :: boolean()
  def matches_current_task?(state, task_ref) do
    state.llm_task_ref == task_ref
  end

  @doc """
  Gets the current page ID being processed.
  """
  @spec current_page_id(processing_state()) :: Uniq.UUID.t() | nil
  def current_page_id(state) do
    state.current_page_id
  end

  @doc """
  Checks if currently processing a page.
  """
  @spec processing?(processing_state()) :: boolean()
  def processing?(state) do
    state.current_page_id != nil
  end

  @doc """
  Cancels timeout timer if active.
  """
  @spec cancel_timeout(processing_state()) :: processing_state()
  def cancel_timeout(state) do
    if state.llm_timeout_ref do
      Process.cancel_timer(state.llm_timeout_ref)
    end

    %{state | llm_timeout_ref: nil}
  end

  @doc """
  Checks if a page can be processed.
  """
  @spec can_process_page?(Uniq.UUID.t()) :: boolean()
  def can_process_page?(page_id) do
    case Documents.get_page(page_id) do
      nil ->
        false

      page ->
        # Page can be processed if:
        # 1. Extraction is pending (initial processing)
        # 2. Extraction has error (retry)
        # 3. Extraction is completed but translation is not completed (translation phase)
        page.extraction_status in ["pending", "error"] or
          (page.extraction_status == "completed" and page.translation_status != "completed")
    end
  end

  @doc """
  Updates page extraction status.
  """
  @spec update_extraction_status(Uniq.UUID.t(), String.t()) :: :ok
  def update_extraction_status(page_id, status) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_extraction(page, %{extraction_status: status})
        :ok
    end
  end

  @doc """
  Updates page extraction status with content.
  """
  @spec update_extraction_status(Uniq.UUID.t(), String.t(), String.t()) :: :ok
  def update_extraction_status(page_id, status, content) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_extraction(page, %{extraction_status: status, content: content})
        :ok
    end
  end

  @doc """
  Updates page translation status.
  """
  @spec update_translation_status(Uniq.UUID.t(), String.t()) :: :ok
  def update_translation_status(page_id, status) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_translation(page, %{translation_status: status})
        :ok
    end
  end

  @doc """
  Updates page translation status with translation.
  """
  @spec update_translation_status(Uniq.UUID.t(), String.t(), String.t()) :: :ok
  def update_translation_status(page_id, status, translation) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_translation(page, %{
          translation_status: status,
          translation: translation
        })

        :ok
    end
  end

  @doc """
  Handles page error.
  """
  @spec handle_page_error(Uniq.UUID.t(), String.t()) :: :ok
  def handle_page_error(page_id, error_message) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_extraction(page, %{
          extraction_status: "error",
          error_message: error_message
        })

        Documents.broadcast_page_update(page)
        :ok
    end
  end

  @doc """
  Resets page for retry.
  """
  @spec reset_page_for_retry(Uniq.UUID.t()) :: :ok
  def reset_page_for_retry(page_id) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_extraction(page, %{extraction_status: "pending", error_message: nil})

        Documents.update_page_translation(page, %{translation_status: "pending"})
        :ok
    end
  end

  @doc """
  Gets page status.
  """
  @spec get_page_status(Uniq.UUID.t()) :: String.t() | nil
  def get_page_status(page_id) do
    case Documents.get_page(page_id) do
      nil -> nil
      page -> page.extraction_status
    end
  end

  @doc """
  Gets page error.
  """
  @spec get_page_error(Uniq.UUID.t()) :: String.t() | nil
  def get_page_error(page_id) do
    case Documents.get_page(page_id) do
      nil -> nil
      page -> page.error_message
    end
  end

  # Private functions

  defp clear_task_state(state) do
    # Cancel timeout timer if active
    state = cancel_timeout(state)

    %{state | current_page_id: nil, llm_task_ref: nil}
  end

  defp mark_page_error(page_id) do
    case Documents.get_page(page_id) do
      nil ->
        :ok

      page ->
        Documents.update_page_extraction(page, %{extraction_status: "error"})
        Documents.broadcast_page_update(page)
    end
  end

  defp do_process_page(page_id, cancelled_documents, opts) do
    LlmProcessor.process_page(page_id, cancelled_documents, opts)
  end

  defp task_timeout_ms do
    config = Application.get_env(:doctrans, __MODULE__, [])
    Keyword.get(config, :task_timeout_ms, @default_task_timeout_ms)
  end
end
