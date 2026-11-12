defmodule Doctrans.Jobs.Ceiling do
  @moduledoc """
  Oban's `timeout/1` for a job that runs under bounds of its own.

  Oban waits forever by default, so every job states a ceiling -- but the
  ceiling is an outer guard, not the bound that is meant to fire. Oban arms the
  timer before `perform/1` and kills the job process when it fires, which no
  lifecycle transition or stage record survives: the page or document is left
  reading "processing" with no verdict written. So each job's ceiling sits a
  margin above the latest moment its own bounds -- a page budget, a document
  budget, a set of model calls at their deadlines -- can return at, and those
  bounds are the deadlines that fire.

  `Oban.Lifeline`'s rescue window in `config/config.exs` is wider than every
  ceiling, so a job still executing is never handed back to the queue as an
  orphan; `Doctrans.ObanLifelineTest` holds that with the shipped bounds.

  **This module must depend on nothing**: the jobs read it at compile time
  next to `Doctrans.Jobs.Keys`, and a dependency here would join their
  compile cycle.
  """

  @margin :timer.minutes(1)

  @doc """
  The ceiling for a job whose own bounds return within `latest_return`
  milliseconds of its start: that, plus the margin.

  Stated as a function of the configured bounds so that raising one of them
  cannot leave the guard below it.
  """
  @spec above(non_neg_integer()) :: pos_integer()
  def above(latest_return) when is_integer(latest_return) and latest_return >= 0,
    do: latest_return + @margin
end
