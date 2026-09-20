defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents using Oban jobs.

  This module provides a simplified interface for document processing
  that delegates to Oban job queues for better reliability and persistence.

  The GenServer itself owns one piece of work: the startup recovery pass, which
  it schedules shortly after boot and then walks one batch at a time so a large
  backlog does not arrive as a single burst.

  ## Configuration

      config :doctrans, Doctrans.Processing.Worker,
        startup_recovery: true,
        startup_delay_ms: 5_000,
        batch_interval_ms: 1_000

  Set `startup_recovery: false` to skip the pass scheduled at boot. The worker
  still starts and still answers `status/0`; only the boot-time schedule is
  skipped. `recover_now/1` runs the same pass on demand regardless of the
  setting.

  The same three keys are accepted as start options, which take precedence, so a
  test can start an instance on either side of the switch without a global
  override.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Jobs.{DocumentExtractionJob, Keys, LlmProcessingJob}
  alias Doctrans.Processing.StartupRecovery
  import Ecto.Query

  # Read from Keys, not from the job modules: a compile-time call to either job
  # is the edge that makes worker.ex part of a compile-connected cycle.
  @document_id_key Keys.document_id()
  @page_id_key Keys.page_id()
  @document_id_match "?->>'#{@document_id_key}' = ?"
  @page_id_match "?->>'#{@page_id_key}' = ANY(?)"

  @default_startup_recovery true
  # Late enough that the rest of the supervision tree is up before the first
  # query, and spaced so recovery of a large backlog stays in the background
  # rather than arriving as one burst.
  @default_startup_delay_ms 5_000
  @default_batch_interval_ms 1_000
  # `recover_now/1` walks every batch back to back, so its ceiling is the size of
  # the backlog rather than the schedule above.
  @recover_now_timeout :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts document extraction for a document using Oban jobs.

  Supports PDF, Word (.docx), and other document formats.
  Document extraction is queued as a job for better reliability and tracking.
  """
  @spec process_document(Ecto.UUID.t(), binary()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def process_document(document_id, file_path) do
    DocumentExtractionJob.enqueue_document(document_id, file_path)
  end

  @doc """
  Queues a page for LLM processing using Oban jobs.

  The page will be processed by the LLM processing job queue.
  Pages are prioritized by page_number to ensure in-order processing.

  ## Options

  - `:page_number` - Page number for priority ordering (lower = processed first)
  """
  @spec queue_page(Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def queue_page(page_id, opts \\ []) do
    page_number = Keyword.get(opts, :page_number, 0)

    # Note: page_number in args does NOT influence job execution order.
    # Oban orders jobs by priority and scheduled_at timestamp.
    # Sequential processing is guaranteed by setting concurrency: 1 for the queue.
    # page_number is included for logging/debugging purposes only.
    %{@page_id_key => page_id, "page_number" => page_number}
    |> Map.merge(LlmProcessingJob.model_args(opts))
    |> Map.put("generation", page_generation(page_id))
    |> LlmProcessingJob.new(priority: 2)
    |> Oban.insert()
    |> Doctrans.Errors.result()
  end

  @doc """
  Queues a page for reprocessing with custom model options using Oban jobs.

  The page will be processed with priority to handle reprocessing requests quickly.

  ## Options

  - `:extraction_model` - Override the default extraction model
  - `:translation_model` - Override the default translation model
  """
  @spec queue_page_reprocess(Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def queue_page_reprocess(page_id, opts \\ []) do
    args = %{@page_id_key => page_id}

    args =
      if opts[:extraction_model],
        do: Map.put(args, "extraction_model", opts[:extraction_model]),
        else: args

    args =
      if opts[:translation_model],
        do: Map.put(args, "translation_model", opts[:translation_model]),
        else: args

    args
    |> Map.put("generation", page_generation(page_id))
    |> LlmProcessingJob.new(priority: 1)
    |> Oban.insert()
    |> Doctrans.Errors.result()
  end

  defp page_generation(page_id) do
    case Documents.get_page(page_id) do
      nil -> nil
      page -> page.processing_generation
    end
  end

  @doc """
  Cancels processing for a specific document.
  Cancels all pending jobs for the document.

  Returns `:ok` on success or `{:error, reason}` for database failures.
  Cancellation may be partial if a later query fails. Unexpected errors propagate.
  """
  @spec cancel_document(Ecto.UUID.t()) :: :ok | {:error, Doctrans.Errors.reason()}
  def cancel_document(document_id) do
    # Cancel all pending jobs for this document using Ecto query
    document_jobs_query =
      from(j in Oban.Job,
        where: fragment(@document_id_match, j.args, ^document_id),
        where: j.state in ["available", "scheduled", "retryable"]
      )

    _ = Oban.cancel_all_jobs(document_jobs_query)

    # Also cancel page jobs
    pages = Documents.list_pages(document_id)
    page_ids = for page <- pages, do: page.id

    _ =
      case page_ids do
        [] ->
          :ok

        active_page_ids ->
          page_jobs_query =
            from(j in Oban.Job,
              where: fragment(@page_id_match, j.args, ^active_page_ids),
              where: j.state in ["available", "scheduled", "retryable"]
            )

          Oban.cancel_all_jobs(page_jobs_query)
      end

    :ok
  rescue
    error in [Ecto.NoResultsError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "Failed to cancel jobs for document #{document_id}: #{Exception.message(error)}"
      )

      {:error, {:database_error, [reason: error]}}
  end

  @doc """
  Returns the current processing status from Oban queues.

  Returns a map with job counts per queue, or zeros on database failures.
  Database failures are logged; unexpected errors propagate.
  """
  @spec status() :: %{
          pdf_extraction: non_neg_integer(),
          llm_processing: non_neg_integer(),
          embedding_generation: non_neg_integer(),
          health_check: non_neg_integer()
        }
  def status do
    repo = Application.get_env(:doctrans, Oban)[:repo] || Doctrans.Repo

    pdf_extraction_query = from(j in Oban.Job, where: j.queue == "pdf_extraction")
    llm_processing_query = from(j in Oban.Job, where: j.queue == "llm_processing")
    embedding_generation_query = from(j in Oban.Job, where: j.queue == "embedding_generation")
    health_check_query = from(j in Oban.Job, where: j.queue == "health_check")

    %{
      pdf_extraction: repo.aggregate(pdf_extraction_query, :count, :id),
      llm_processing: repo.aggregate(llm_processing_query, :count, :id),
      embedding_generation: repo.aggregate(embedding_generation_query, :count, :id),
      health_check: repo.aggregate(health_check_query, :count, :id)
    }
  rescue
    error in [Ecto.NoResultsError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("Failed to read Oban queue status: #{Exception.message(error)}")

      %{pdf_extraction: 0, llm_processing: 0, embedding_generation: 0, health_check: 0}
  end

  @doc """
  Runs the startup recovery pass now and returns when it has finished.

  Works even when the boot-time pass is disabled (`startup_recovery: false` only
  skips the schedule in `init/1`). Unlike that pass, this one walks every batch
  without pausing between them, so the reply is the signal that recovery is
  complete rather than merely started.
  """
  @spec recover_now(GenServer.server()) :: :ok
  def recover_now(server \\ __MODULE__) do
    GenServer.call(server, :recover_now, @recover_now_timeout)
  end

  @impl true
  def init(opts) do
    config = config(opts)

    if config[:startup_recovery] do
      # Schedule recovery of incomplete documents after init completes
      Process.send_after(self(), :recover_incomplete_documents, config[:startup_delay_ms])

      Logger.info(
        "Processing.Worker started, recovering incomplete work in " <>
          "#{config[:startup_delay_ms]}ms"
      )
    else
      Logger.info("Processing.Worker startup recovery is disabled")
    end

    {:ok, %{batch_interval_ms: config[:batch_interval_ms]}}
  end

  # Start options win over the application environment, so a test can start an
  # instance of its own on either side of the switch without a global override.
  defp config(opts) do
    app_config = Application.get_env(:doctrans, __MODULE__, [])

    for {key, default} <- [
          startup_recovery: @default_startup_recovery,
          startup_delay_ms: @default_startup_delay_ms,
          batch_interval_ms: @default_batch_interval_ms
        ] do
      {key, Keyword.get(opts, key, Keyword.get(app_config, key, default))}
    end
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status(), state}
  end

  def handle_call(:recover_now, _from, state) do
    {:reply, run_pass({:documents, nil}), state}
  end

  defp run_pass(:done), do: :ok
  defp run_pass(cursor), do: cursor |> StartupRecovery.run_batch() |> run_pass()

  @impl true
  def handle_info(:recover_incomplete_documents, state) do
    send(self(), {:recover_batch, {:documents, nil}})
    {:noreply, state}
  end

  def handle_info({:recover_batch, cursor}, state) do
    _ =
      case StartupRecovery.run_batch(cursor) do
        :done -> :ok
        next -> Process.send_after(self(), {:recover_batch, next}, state.batch_interval_ms)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
