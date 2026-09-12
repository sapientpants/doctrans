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

  require Logger

  alias Doctrans.Documents.Page
  alias Doctrans.Errors
  alias Doctrans.Jobs.Keys
  alias Doctrans.Search.Indexer

  @page_id_key Keys.page_id()
  @revision_key Keys.revision()

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
    page_id
    |> Indexer.index_page(Map.get(args, @revision_key))
    |> report_retry(job, page_id)
  end

  # Indexing no longer owns its retry loop, so the retry series the dashboard
  # charts (`type: :embedding`, alongside :extraction and :translation) has to be
  # emitted from the layer that does own it — here.
  defp report_retry({:error, reason} = outcome, %Oban.Job{} = job, page_id) do
    if job.attempt >= job.max_attempts do
      Logger.error(
        "Indexing exhausted #{job.max_attempts} attempts for page #{page_id}: #{inspect(reason)}"
      )

      :telemetry.execute(
        [:doctrans, :retry, :exhausted],
        %{count: 1},
        %{type: :embedding, page_id: page_id}
      )
    else
      :telemetry.execute(
        [:doctrans, :retry, :attempt],
        %{count: 1},
        %{type: :embedding, page_id: page_id, attempt: job.attempt}
      )
    end

    outcome
  end

  defp report_retry(outcome, _job, _page_id), do: outcome
end
