defmodule Doctrans.Jobs.LlmProcessingJob do
  @moduledoc """
  The Oban side of a page's content work.

  `Doctrans.Processing.PageWork.queue/3` is the one place a job of this kind is
  queued, and the one statement of the argument map `perform/1` destructures:
  the page, its generation, and the models its run chose. Uniqueness on the
  page keeps one job per page across every active state.

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
  alias Doctrans.Processing.{LlmProcessor, Run}

  @page_id_key Keys.page_id()

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
    page = Documents.get_page(page_id)
    _ = if Run.current?(page, generation: generation), do: Lifecycle.settle(page)
    :ok
  end
end
