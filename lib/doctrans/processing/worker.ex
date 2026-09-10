defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents using Oban jobs.

  This module provides a simplified interface for document processing
  that delegates to Oban job queues for better reliability and persistence.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.StartupRecovery
  import Ecto.Query

  @document_id_key DocumentExtractionJob.document_id_key()
  @page_id_key LlmProcessingJob.page_id_key()
  @document_id_match "?->>'#{@document_id_key}' = ?"
  @page_id_match "?->>'#{@page_id_key}' = ANY(?)"

  @spec start_link(term()) :: GenServer.on_start()
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

  @impl true
  def init(_opts) do
    # Schedule recovery of incomplete documents after init completes
    Process.send_after(self(), :recover_incomplete_documents, 5_000)

    {:ok, %{}}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status(), state}
  end

  @impl true
  def handle_info(:recover_incomplete_documents, state) do
    send(self(), {:recover_batch, {:documents, nil}})
    {:noreply, state}
  end

  def handle_info({:recover_batch, cursor}, state) do
    _ =
      case StartupRecovery.run_batch(cursor) do
        :done -> :ok
        next -> Process.send_after(self(), {:recover_batch, next}, 1_000)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
