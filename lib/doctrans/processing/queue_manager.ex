defmodule Doctrans.Processing.QueueManager do
  @moduledoc """
  Manages a two-level queue system for document processing.

  Handles:
  - Document queue: documents waiting for their turn
  - Page queue: pages of the active document being processed sequentially
  - Cancelled documents tracking
  - Page model options for reprocessing
  """

  require Logger

  def start_link do
    Agent.start_link(fn -> new_state() end, name: __MODULE__)
  end

  @doc """
  Creates a new queue state.
  """
  @spec new_state() :: map()
  def new_state do
    %{
      page_queue: :queue.new(),
      document_queue: :queue.new(),
      cancelled_documents: MapSet.new(),
      page_model_opts: %{},
      queue: :queue.new(),
      failed: [],
      completed: []
    }
  end

  @doc """
  Gets the current queue state.
  """
  @spec get_state() :: map()
  def get_state do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Adds a job to the queue.
  """
  @spec add_job(map()) :: :ok | {:error, :queue_full}
  def add_job(job) do
    Agent.get_and_update(__MODULE__, fn state ->
      current_size = :queue.len(state.queue)

      if current_size >= 10 do
        {{:error, :queue_full}, state}
      else
        # Handle priority - high priority jobs go to front
        queue =
          case job[:priority] do
            :high ->
              # Convert to list, prepend high priority job, convert back to queue
              current_items = :queue.to_list(state.queue)
              :queue.from_list([job | current_items])

            _ ->
              :queue.in(job, state.queue)
          end

        Logger.info("Adding job #{job.id} to queue with priority #{job[:priority] || :normal}")
        {{:ok}, %{state | queue: queue}}
      end
    end)
  end

  @doc """
  Gets the next job from the queue.
  """
  @spec get_next_job() :: {:ok, map()} | {:error, :empty}
  def get_next_job do
    Agent.get_and_update(__MODULE__, fn state ->
      case :queue.out(state.queue) do
        {:empty, _} ->
          {{:error, :empty}, state}

        {{:value, job}, queue} ->
          new_state = %{state | queue: queue}
          {{:ok, job}, new_state}
      end
    end)
  end

  @doc """
  Starts processing a job.
  """
  @spec start_processing(String.t()) :: :ok
  def start_processing(job_id) do
    Logger.info("Starting processing for job #{job_id}")
    :ok
  end

  @doc """
  Handles job timeout.
  """
  @spec handle_job_timeout(String.t()) :: :ok
  def handle_job_timeout(job_id) do
    Agent.update(__MODULE__, fn state ->
      failed_job = %{id: job_id, reason: :timeout}
      failed = [failed_job | state.failed]
      Logger.warning("Job #{job_id} timed out")
      %{state | failed: failed}
    end)

    :ok
  end

  @doc """
  Gets queue statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    state = get_state()

    %{
      total_jobs: :queue.len(state.queue) + length(state.completed) + length(state.failed),
      pending_jobs: :queue.len(state.queue),
      processing_jobs: 0,
      completed_jobs: length(state.completed),
      failed_jobs: length(state.failed),
      queued: :queue.len(state.queue)
    }
  end

  @doc """
  Clears completed jobs.
  """
  @spec clear_completed() :: :ok
  def clear_completed do
    Agent.update(__MODULE__, fn state ->
      Logger.info("Clearing completed jobs")
      %{state | completed: []}
    end)

    :ok
  end

  @doc """
  Removes a job by ID.
  """
  @spec remove_job(String.t()) :: :ok
  def remove_job(job_id) do
    Agent.update(__MODULE__, fn state ->
      Logger.info("Removing job #{job_id}")
      # Filter out the job with matching ID
      queue_items = :queue.to_list(state.queue)
      filtered_items = Enum.reject(queue_items, fn job -> job.id == job_id end)
      new_queue = :queue.from_list(filtered_items)
      %{state | queue: new_queue}
    end)

    :ok
  end

  @doc """
  Completes a job.
  """
  @spec complete_job(String.t(), atom()) :: :ok
  def complete_job(job_id, result) do
    Agent.update(__MODULE__, fn state ->
      completed_job = %{id: job_id, status: result}
      completed = [completed_job | state.completed]
      Logger.info("Job #{job_id} completed with result #{result}")
      %{state | completed: completed}
    end)

    :ok
  end
end
