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

  alias Doctrans.Documents.Page
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, Keys, LlmProcessingJob}
  alias Doctrans.Repo

  @active ~w(available scheduled executing retryable suspended)
  @waiting ~w(available scheduled retryable suspended)

  # Read from `Keys` rather than written out: the argument key is one fact, and
  # a literal here would drift silently from the job that writes it.
  @document_id_arg "?->>'#{Keys.document_id()}'"
  @page_id_arg "?->>'#{Keys.page_id()}'"

  @rank %{idle: 0, queued: 1, retrying: 2, running: 3}

  @type activity :: :idle | :queued | :running | :retrying

  @doc """
  Reports the live activity of the document's content and indexing pipelines.
  """
  @spec for_document(Ecto.UUID.t()) :: %{content: activity(), index: activity()}
  def for_document(document_id) do
    index_worker = Oban.Worker.to_string(EmbeddingJob)

    document_id
    |> active_jobs(index_worker)
    |> Repo.all()
    |> Enum.reduce(%{content: :idle, index: :idle}, fn {worker, state, attempt}, acc ->
      pipeline = if worker == index_worker, do: :index, else: :content
      Map.update!(acc, pipeline, &strongest(&1, classify(state, attempt)))
    end)
  end

  # One query for both pipelines: the alternative is three round trips whose
  # results are read as a single instant anyway. Page ids are cast to text
  # because `args->>'page_id'` is text, not uuid.
  defp active_jobs(document_id, index_worker) do
    page_ids = from p in Page, where: p.document_id == ^document_id, select: type(p.id, :string)
    page_workers = [Oban.Worker.to_string(LlmProcessingJob), index_worker]

    from(j in Oban.Job,
      where: j.state in ^@active,
      where:
        (j.worker == ^Oban.Worker.to_string(DocumentExtractionJob) and
           fragment(@document_id_arg, j.args) == ^document_id) or
          (j.worker in ^page_workers and
             fragment(@page_id_arg, j.args) in subquery(page_ids)),
      select: {j.worker, j.state, j.attempt}
    )
  end

  defp classify("executing", _attempt), do: :running
  defp classify(state, attempt) when attempt > 0 and state in @waiting, do: :retrying
  defp classify(_state, _attempt), do: :queued

  defp strongest(current, candidate),
    do: if(@rank[current] >= @rank[candidate], do: current, else: candidate)
end
