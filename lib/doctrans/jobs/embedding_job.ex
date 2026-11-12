defmodule Doctrans.Jobs.EmbeddingJob do
  @moduledoc """
  Durable indexing of one page revision.

  The request survives a restart, because it is a row rather than a GenServer
  message, and the retry schedule is Oban's rather than a sleeping task's.

  Uniqueness is keyed on the page *and* its `content_revision`, so repeating the
  request for a revision already queued or running is a no-op, while a revision
  bump — a re-extraction, a page reset — is a distinct unit of work that queues
  alongside the one it supersedes. The superseded job cannot win: every write
  `Doctrans.Search.Indexer` makes is fenced on the revision it was queued for.

  `max_attempts` is higher than the sibling job modules' because an attempt here
  is cheap to resume: chunks that already carry a vector are skipped, so a retry
  costs only the chunks still outstanding. Extraction and translation restart
  their whole unit of work, which is why they stop sooner.
  """

  use Oban.Worker,
    queue: :embedding_generation,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:page_id, :revision],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Config.Embedding
  alias Doctrans.Documents.Page
  alias Doctrans.Errors
  alias Doctrans.Jobs.{Ceiling, Keys, RetryTelemetry}
  alias Doctrans.Search.Indexer

  @page_id_key Keys.page_id()
  @revision_key Keys.revision()

  @doc """
  Oban's ceiling on one attempt: the page's indexing budget, the receive
  window the last call may outlive it by, and `Doctrans.Jobs.Ceiling`'s margin.

  The ceiling is an outer guard, not the budget. The budget is
  `Embedding.job_timeout/0`: `perform/1` arms it as it begins and `Indexer`
  clamps every embedding call's deadline against it, so a page that runs out
  fails cleanly with its finished chunks preserved, and the retry resumes
  rather than restarts. `Doctrans.Processing.RequestBounds` lets a call
  return one receive window after its deadline, and that window is at most
  `Embedding.timeout/0`, so the last call may end that long past the budget;
  the guard allows for it, so that the budget is the deadline that fires.
  """
  @impl true
  def timeout(_job), do: Ceiling.above(Embedding.job_timeout() + Embedding.timeout())

  @doc """
  Builds the argument map `perform/1` destructures.

  Stated here so that every enqueue site agrees with the consumer on the shape
  and on the key names, rather than each restating them.
  """
  @spec page_args(Page.t()) :: map()
  def page_args(page),
    do: %{@page_id_key => page.id, @revision_key => page.content_revision}

  @doc "Queues indexing for the page's current revision."
  @spec enqueue_page(Page.t()) :: {:ok, Oban.Job.t()} | {:error, Errors.reason()}
  def enqueue_page(page) do
    page
    |> page_args()
    |> new()
    |> Oban.insert()
    |> Errors.result()
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args} = job) do
    # The budget starts here, before the page is read and chunked: counted from
    # any later point it would outlast the guard above.
    deadline = Indexer.budget_from_now()

    page_id
    |> Indexer.index_page(Map.get(args, @revision_key), deadline: deadline)
    |> report_retry(job, page_id)
  end

  # Indexing owns no retry loop, so its retry series is reported from the layer
  # that does own it -- here, through the one emission site every job shares.
  defp report_retry({:error, reason} = outcome, %Oban.Job{} = job, page_id) do
    :ok = RetryTelemetry.report(job, :embedding, page_id, reason)
    outcome
  end

  defp report_retry(outcome, _job, _page_id), do: outcome
end
