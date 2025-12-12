defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Background worker for processing documents using Oban jobs.

  This module provides a simplified interface for document processing
  that delegates to Oban job queues for better reliability and persistence.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Jobs.{LlmProcessingJob, PdfExtractionJob}
  import Ecto.Query

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts PDF extraction for a document using Oban jobs.

  PDF extraction is queued as a job for better reliability and tracking.
  """
  def process_document(document_id, pdf_path) do
    %{"document_id" => document_id, "pdf_path" => pdf_path}
    |> PdfExtractionJob.new()
    |> Oban.insert()
  end

  @doc """
  Queues a page for LLM processing using Oban jobs.

  The page will be processed by the LLM processing job queue.
  Pages are prioritized by page_number to ensure in-order processing.

  ## Options

  - `:page_number` - Page number for priority ordering (lower = processed first)
  """
  def queue_page(page_id, opts \\ []) do
    page_number = Keyword.get(opts, :page_number, 0)

    # Note: page_number in args does NOT influence job execution order.
    # Oban orders jobs by priority and scheduled_at timestamp.
    # Sequential processing is guaranteed by setting concurrency: 1 for the queue.
    # page_number is included for logging/debugging purposes only.
    %{"page_id" => page_id, "page_number" => page_number}
    |> LlmProcessingJob.new(priority: 2)
    |> Oban.insert()
  end

  @doc """
  Queues a page for reprocessing with custom model options using Oban jobs.

  The page will be processed with priority to handle reprocessing requests quickly.

  ## Options

  - `:extraction_model` - Override the default extraction model
  - `:translation_model` - Override the default translation model
  """
  def queue_page_reprocess(page_id, opts \\ []) do
    args = %{"page_id" => page_id}

    args =
      if opts[:extraction_model],
        do: Map.put(args, "extraction_model", opts[:extraction_model]),
        else: args

    args =
      if opts[:translation_model],
        do: Map.put(args, "translation_model", opts[:translation_model]),
        else: args

    args
    |> LlmProcessingJob.new(priority: 1)
    |> Oban.insert()
  end

  @doc """
  Cancels processing for a specific document.
  Cancels all pending jobs for the document.
  """
  def cancel_document(document_id) do
    # Cancel all pending jobs for this document using Ecto query
    document_jobs_query =
      from(j in Oban.Job,
        where: fragment("args->>'document_id' = ?", ^document_id),
        where: j.state in ["available", "scheduled", "retryable"]
      )

    Oban.cancel_all_jobs(document_jobs_query)

    # Also cancel page jobs
    pages = Documents.list_pages(document_id)
    page_ids = Enum.map(pages, & &1.id)

    unless Enum.empty?(page_ids) do
      page_jobs_query =
        from(j in Oban.Job,
          where: fragment("args->>'page_id' = ANY(?)", ^page_ids),
          where: j.state in ["available", "scheduled", "retryable"]
        )

      Oban.cancel_all_jobs(page_jobs_query)
    end

    :ok
  rescue
    error in RuntimeError ->
      Logger.warning("Failed to cancel document jobs: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Returns the current processing status from Oban queues.

  Returns a map with job counts per queue, or zeros if Oban is not available.
  """
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
    _ ->
      # Oban not available (likely in tests) - return zeros
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
    Logger.info("Recovering incomplete documents...")

    # Find documents with incomplete processing and queue them
    Documents.list_incomplete_documents()
    |> Enum.each(fn document ->
      case document.status do
        "extracting" ->
          Logger.info("Re-queuing extracting document: #{document.id}")

          if document.file_path do
            process_document(document.id, document.file_path)
          else
            Logger.warning("Document #{document.id} has no file_path, skipping recovery")
          end

        "processing" ->
          Logger.info("Re-queuing processing document: #{document.id}")

          Documents.list_pages(document.id)
          |> Enum.each(fn page ->
            queue_page(page.id, page_number: page.page_number)
          end)

        "queued" ->
          Logger.info("Re-queuing queued document: #{document.id}")

          if document.file_path do
            process_document(document.id, document.file_path)
          else
            Logger.warning("Document #{document.id} has no file_path, skipping recovery")
          end

        _ ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
