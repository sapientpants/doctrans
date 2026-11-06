defmodule Doctrans.Jobs.LlmProcessingJob do
  @moduledoc """
  The Oban side of a page's content work.

  `Doctrans.Processing.PageWork` owns the work: `queue/3` is the one place a
  job of this kind is queued and the one statement of the argument map
  `perform/1` destructures -- the page, its generation, and the models its run
  chose -- and `attempt/2` is what one run of the job does, settling the
  document when the outcome is final. What is decided here is only what Oban
  needs to know: how the row's string-keyed arguments read as options, whether
  this is the job's last attempt, and which retry series a failure counts in.

  Uniqueness on the page keeps one job per page across every active state. The
  retry schedule is Oban's: the attempt calls each model once and reports a
  transient failure as `{:error, _}` for Oban to back off and retry, or a
  permanent one as `{:cancel, _}` so that no attempt is spent repeating it.
  `max_attempts` therefore bounds the model calls a page can cost, and no
  attempt sleeps while holding the queue's single slot.
  """

  use Oban.Worker,
    queue: :llm_processing,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:page_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Jobs.{Keys, RetryTelemetry}
  alias Doctrans.Processing.PageWork

  @page_id_key Keys.page_id()

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args} = job) do
    page_id
    |> PageWork.attempt(attempt_opts(args, job))
    |> report_retry(job, page_id)
  end

  # Oban persists JSON with string keys; the attempt expects keyword options.
  # A row without a generation names `nil`, which is what a page that never
  # had one holds.
  defp attempt_opts(args, job) do
    models =
      for key <- [:extraction_model, :translation_model],
          model = Map.get(args, Atom.to_string(key)),
          not is_nil(model),
          do: {key, model}

    models ++
      [generation: Map.get(args, "generation"), last_attempt?: RetryTelemetry.final_attempt?(job)]
  end

  # The attempt owns no retry loop, so its retry series is reported from the
  # layer that does own it -- here, through the one emission site every job
  # shares. A `{:cancel, _}` is not a retry and reports nothing, just as a
  # permanent error never did.
  defp report_retry({:error, {code, _bindings} = reason} = outcome, %Oban.Job{} = job, page_id)
       when code in [:page_extraction_failed, :page_translation_failed] do
    RetryTelemetry.report(job, stage(code), page_id, reason)
    outcome
  end

  defp report_retry(outcome, _job, _page_id), do: outcome

  defp stage(:page_extraction_failed), do: :extraction
  defp stage(:page_translation_failed), do: :translation
end
