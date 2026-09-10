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

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.{LlmProcessor, Run}

  @page_id_key "page_id"

  @doc false
  def page_id_key, do: @page_id_key

  def model_args(opts) do
    opts
    |> Keyword.take([:extraction_model, :translation_model])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args} = job) do
    # Oban persists JSON with string keys; the processor expects keyword options.
    opts =
      for key <- [:extraction_model, :translation_model],
          model = Map.get(args, Atom.to_string(key)),
          not is_nil(model),
          do: {key, model}

    result =
      LlmProcessor.process_page(
        page_id,
        MapSet.new(),
        Keyword.put(opts, :generation, Map.get(args, "generation"))
      )

    if match?({:error, _}, result) && job.attempt >= job.max_attempts do
      _ = publish_final_error(page_id, Map.get(args, "generation"), result)
    end

    result
  end

  defp publish_final_error(page_id, generation, {:error, reason}) do
    case Documents.get_page(page_id) do
      %{processing_generation: ^generation} = page ->
        Run.with_page(page, fn _ ->
          document = Documents.get_document!(page.document_id)

          with {:ok, document} <- Documents.update_document_status(document, "error", reason) do
            Topics.broadcast_document_update(document)
          end
        end)

      _ ->
        :ok
    end
  end
end
