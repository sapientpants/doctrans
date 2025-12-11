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
  """
  def queue_page(page_id) do
    %{"page_id" => page_id}
    |> LlmProcessingJob.new()
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
    # Cancel all pending jobs for this document
    Oban.cancel_all_jobs(Oban.Job, where: "args->>'document_id' = $1", args: [document_id])

    # Also cancel page jobs
    pages = Documents.list_pages(document_id: document_id)
    page_ids = Enum.map(pages, & &1.id)

    unless Enum.empty?(page_ids) do
      placeholders = Enum.map_join(page_ids, ",", &"'#{&1}'")
      Oban.cancel_all_jobs(Oban.Job, where: "args->>'page_id' IN (#{placeholders})")
    end

    :ok
  rescue
    RuntimeError ->
      # Oban not available (likely in tests)
      :ok
  end

  @doc """
  Returns the current processing status from Oban queues.
  """
  def status do
    repo = Application.get_env(:doctrans, Oban)[:repo] || Doctrans.Repo

    pdf_extraction_query = from(j in Oban.Job, where: j.queue == "pdf_extraction")
    llm_processing_query = from(j in Oban.Job, where: j.queue == "llm_processing")
    embedding_generation_query = from(j in Oban.Job, where: j.queue == "embedding_generation")
    health_checks_query = from(j in Oban.Job, where: j.queue == "health_checks")

    %{
      pdf_extraction: repo.aggregate(pdf_extraction_query, :count, :id),
      llm_processing: repo.aggregate(llm_processing_query, :count, :id),
      embedding_generation: repo.aggregate(embedding_generation_query, :count, :id),
      health_checks: repo.aggregate(health_checks_query, :count, :id)
    }
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
    Documents.list_documents(status: "extracting")
    |> Enum.each(fn document ->
      Logger.info("Re-queuing incomplete document: #{document.id}")
      # Skip if file_path is not available
      if document.file_path do
        process_document(document.id, document.file_path)
      else
        Logger.warning("Document #{document.id} has no file_path, skipping recovery")
      end
    end)

    Documents.list_documents(status: "processing")
    |> Enum.each(fn document ->
      Logger.info("Re-queuing processing document: #{document.id}")

      Documents.list_pages(document_id: document.id)
      |> Enum.each(fn page ->
        queue_page(page.id)
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
