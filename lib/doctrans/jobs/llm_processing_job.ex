defmodule Doctrans.Jobs.LlmProcessingJob do
  @moduledoc """
  Job for processing individual pages through LLM pipeline.

  This job handles both extraction and translation of page content
  using vision and text models.
  """

  use Oban.Worker,
    queue: :llm_processing,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:page_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Processing.LlmProcessor

  @page_id_key "page_id"

  @doc false
  def page_id_key, do: @page_id_key

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id, "opts" => opts}}) do
    LlmProcessor.process_page(page_id, MapSet.new(), opts || [])
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id}}) do
    LlmProcessor.process_page(page_id, MapSet.new(), [])
  end
end
