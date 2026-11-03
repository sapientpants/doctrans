defmodule Doctrans.Jobs.LlmProcessingJob do
  @moduledoc """
  Job for processing individual pages through LLM pipeline.

  This job handles both extraction and translation of page content
  using vision and text models.

  The retry schedule is Oban's: `Doctrans.Processing.LlmProcessor` calls each
  model once per attempt and reports a transient failure as `{:error, _}` for
  Oban to back off and retry, or a permanent one as `{:cancel, _}` so that no
  attempt is spent repeating it. `max_attempts` therefore bounds the model calls
  a page can cost, and no attempt sleeps while holding the queue's single slot.
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
  alias Doctrans.Documents.Lifecycle
  alias Doctrans.Jobs.{Keys, RetryTelemetry}
  alias Doctrans.Processing.LlmProcessor

  @page_id_key Keys.page_id()

  @spec model_args(keyword()) :: %{String.t() => String.t()}
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

  @doc """
  Queues a freshly extracted page for processing at the ordinary priority.

  The page's own `processing_generation` is the guard a replayed job checks
  against, so the caller passes the page it just read rather than an id. The
  options are the run's model choices (`Run.model_opts/1`). Uniqueness on
  `page_id` returns the job already queued for the page instead of a second one.
  """
  @spec enqueue_page(Documents.Page.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_page(%Documents.Page{} = page, opts \\ []) do
    page
    |> page_args(page.processing_generation, model_args(opts))
    |> new(priority: 2)
    |> Oban.insert()
    |> Doctrans.Errors.result()
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args} = job) do
    generation = Map.get(args, "generation")

    try do
      LlmProcessor.process_page(page_id, processor_opts(args, generation))
    catch
      # A crash returns no result, so settle here: the processor has marked the
      # stage it was in as failed, Oban discards the job after the last attempt,
      # and nothing else would settle the document until the next recovery pass.
      kind, reason ->
        _ = settle(job, page_id, generation, {:error, :crashed})
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        _ = report_retry(result, job, page_id)
        _ = settle(job, page_id, generation, result)
        result
    end
  end

  # Oban persists JSON with string keys; the processor expects keyword options.
  defp processor_opts(args, generation) do
    models =
      for key <- [:extraction_model, :translation_model],
          model = Map.get(args, Atom.to_string(key)),
          not is_nil(model),
          do: {key, model}

    Keyword.put(models, :generation, generation)
  end

  # The processor owns no retry loop, so its retry series is reported from the
  # layer that does own it -- here, through the one emission site every job
  # shares. A `{:cancel, _}` is not a retry and reports nothing, just as a
  # permanent error never did.
  defp report_retry({:error, {code, _bindings} = reason}, %Oban.Job{} = job, page_id)
       when code in [:page_extraction_failed, :page_translation_failed] do
    RetryTelemetry.report(job, stage(code), page_id, reason)
  end

  defp report_retry(_outcome, _job, _page_id), do: :ok

  defp stage(:page_extraction_failed), do: :extraction
  defp stage(:page_translation_failed), do: :translation

  # A failure is final when Oban will not run the job again: a cancel, or an
  # error on the last attempt. Only then is the document settled on the page's
  # account; a successful run settles it from the processor. The document
  # reaches `error` there and nowhere else, once every page has settled, so a
  # page exhausting its retries while its siblings still run changes nothing
  # yet, and one failing after the user cancelled changes nothing at all.
  defp settle(job, page_id, generation, result) do
    if final?(job, result), do: settle_page(page_id, generation), else: :ok
  end

  defp final?(_job, {:cancel, _reason}), do: true
  defp final?(job, {:error, _reason}), do: RetryTelemetry.final_attempt?(job)
  defp final?(_job, _result), do: false

  defp settle_page(page_id, generation) do
    case Documents.get_page(page_id) do
      %{processing_generation: ^generation} = page ->
        _ = Lifecycle.settle(page)
        :ok

      _ ->
        :ok
    end
  end
end
