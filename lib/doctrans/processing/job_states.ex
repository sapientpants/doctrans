defmodule Doctrans.Processing.JobStates do
  @moduledoc """
  What Oban is currently doing for one document, split by pipeline.

  The content pipeline (extraction and per-page LLM work) and the indexing
  pipeline (embeddings) are reported separately because they fail and recover
  separately: a document whose translation finished can still be mid-indexing,
  and a stalled index must not read as stalled content.

  Each matching job is classified from its own row — `executing` is running, a
  waiting job that has already burned an attempt is retrying, anything else is
  queued — and the jobs of a pipeline collapse by the precedence

      running > retrying > queued > idle

  so the pipeline reports the most advanced thing any of its jobs is doing. A
  job executing on its second attempt is therefore reported as running, not
  retrying: the retry is how it got here, running is what it is doing now.
  """

  import Ecto.Query

  alias Doctrans.Jobs.{EmbeddingJob, LlmProcessingJob}
  alias Doctrans.Processing.JobQuery
  alias Doctrans.Repo

  @rank %{idle: 0, queued: 1, retrying: 2, running: 3}

  @type activity :: :idle | :queued | :running | :retrying

  @doc """
  Reports the live activity of the document's content and indexing pipelines.
  """
  @spec for_document(Ecto.UUID.t()) :: %{content: activity(), index: activity()}
  def for_document(document_id) do
    index_worker = Oban.Worker.to_string(EmbeddingJob)

    document_id
    |> JobQuery.document_work_query([LlmProcessingJob, EmbeddingJob])
    |> select([j], {j.worker, j.state, j.attempt})
    |> Repo.all()
    |> Enum.reduce(%{content: :idle, index: :idle}, fn {worker, state, attempt}, acc ->
      pipeline = if worker == index_worker, do: :index, else: :content
      Map.update!(acc, pipeline, &strongest(&1, classify(state, attempt)))
    end)
  end

  # The query returns active jobs only, so a job that is not executing is
  # waiting in one of `JobQuery.waiting_states/0`; the attempt count then says
  # whether it is waiting for its first run or for a retry.
  defp classify("executing", _attempt), do: :running
  defp classify(_state, attempt) when attempt > 0, do: :retrying
  defp classify(_state, _attempt), do: :queued

  defp strongest(current, candidate),
    do: if(@rank[current] >= @rank[candidate], do: current, else: candidate)
end
