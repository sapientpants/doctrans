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
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.{LlmProcessor, Run}

  @page_id_key Keys.page_id()

  def model_args(opts) do
    opts
    |> Keyword.take([:extraction_model, :translation_model])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc """
  Builds the argument map `perform/1` destructures.

  Stated here so that every enqueue site agrees with the consumer on the shape
  and on the key names, rather than each restating them.
  """
  @spec page_args(Documents.Page.t(), integer() | nil, map()) :: map()
  def page_args(page, generation, model_args) do
    Map.merge(
      %{
        @page_id_key => page.id,
        "page_number" => page.page_number,
        "generation" => generation
      },
      model_args
    )
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args} = job) do
    # Oban persists JSON with string keys; the processor expects keyword options.
    opts =
      for key <- [:extraction_model, :translation_model],
          model = Map.get(args, Atom.to_string(key)),
          not is_nil(model),
          do: {key, model}

    generation = Map.get(args, "generation")

    try do
      LlmProcessor.process_page(page_id, MapSet.new(), Keyword.put(opts, :generation, generation))
    catch
      # A crash returns no result, so settle here: Oban discards the job after
      # the last attempt and nothing else would move the document off
      # "processing" until the next startup recovery pass.
      kind, reason ->
        _ = settle_exhausted_job(job, page_id, generation, {:error, crash_reason(kind, reason)})
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        _ = settle_exhausted_job(job, page_id, generation, result)
        result
    end
  end

  defp settle_exhausted_job(job, page_id, generation, result) do
    if match?({:error, _}, result) and job.attempt >= job.max_attempts,
      do: publish_final_error(page_id, generation, result),
      else: :ok
  end

  defp crash_reason(kind, reason),
    do: {:operation_failed, [reason: Exception.format(kind, reason)]}

  defp publish_final_error(page_id, generation, {:error, reason}) do
    case Documents.get_page(page_id) do
      %{processing_generation: ^generation} = page ->
        Run.with_page(page, fn _ ->
          document = Documents.get_document!(page.document_id)

          Documents.update_document_status(document, "error", reason)
        end)
        |> case do
          {:ok, document} -> Topics.broadcast_document_update(document)
          error -> error
        end

      _ ->
        :ok
    end
  end
end
