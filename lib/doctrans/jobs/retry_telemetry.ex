defmodule Doctrans.Jobs.RetryTelemetry do
  @moduledoc """
  The retry series the dashboard charts, emitted from the layer that owns the
  retries.

  No processor keeps a retry loop of its own: each calls its model once per
  attempt and reports the failure, and Oban's schedule decides whether there is
  another attempt. So the `[:doctrans, :retry, :attempt]` and
  `[:doctrans, :retry, :exhausted]` events are emitted here, once, for every
  job that reports a retryable failure -- `type: :extraction`, `:translation`
  and `:embedding` are the same series from the same site.
  """

  require Logger

  @typedoc "Which stage of a page's processing the failure belongs to."
  @type type :: :extraction | :translation | :embedding

  @doc "Whether Oban will not run `job` again after this attempt."
  @spec final_attempt?(Oban.Job.t()) :: boolean()
  def final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts

  @doc """
  Reports a retryable failure of `job` for the page it processes.

  On the last attempt the failure is logged with its reason and counted as
  exhausted; before that it is counted as an attempt Oban will retry.
  """
  @spec report(Oban.Job.t(), type(), Ecto.UUID.t(), term()) :: :ok
  def report(%Oban.Job{} = job, type, page_id, reason) do
    if final_attempt?(job) do
      Logger.error(
        "#{label(type)} exhausted #{job.max_attempts} attempts for page #{page_id}: #{inspect(reason)}"
      )

      :telemetry.execute(
        [:doctrans, :retry, :exhausted],
        %{count: 1},
        %{type: type, page_id: page_id}
      )
    else
      :telemetry.execute(
        [:doctrans, :retry, :attempt],
        %{count: 1},
        %{type: type, page_id: page_id, attempt: job.attempt}
      )
    end
  end

  defp label(:extraction), do: "Extraction"
  defp label(:translation), do: "Translation"
  defp label(:embedding), do: "Indexing"
end
