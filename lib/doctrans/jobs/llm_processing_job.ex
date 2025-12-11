defmodule Doctrans.Jobs.LlmProcessingJob do
  @moduledoc """
  Job for processing individual pages through LLM pipeline.

  This job handles both extraction and translation of page content
  using vision and text models.
  """

  use Oban.Worker, queue: :llm_processing, max_attempts: 3

  alias Doctrans.Processing.LlmProcessor

  @impl true
  def perform(%Oban.Job{args: %{"page_id" => page_id, "opts" => opts}}) do
    LlmProcessor.process_page(page_id, MapSet.new(), opts || [])
  end

  @impl true
  def perform(%Oban.Job{args: %{"page_id" => page_id}}) do
    LlmProcessor.process_page(page_id, MapSet.new(), [])
  end

  @doc """
  Creates a new LLM processing job.
  """
  def new(args) do
    %{
      args: args,
      queue: :llm_processing,
      worker: __MODULE__
    }
    |> Oban.Job.new()
  end
end
