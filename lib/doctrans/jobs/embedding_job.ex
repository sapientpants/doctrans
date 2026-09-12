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
  """

  use Oban.Worker,
    queue: :embedding_generation,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:page_id, :revision],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Documents.Page
  alias Doctrans.Errors
  alias Doctrans.Jobs.Keys
  alias Doctrans.Search.Indexer

  @page_id_key Keys.page_id()

  @doc """
  Builds the argument map `perform/1` destructures.

  Stated here so that every enqueue site agrees with the consumer on the shape
  and on the key names, rather than each restating them.
  """
  @spec page_args(Page.t()) :: map()
  def page_args(page),
    do: %{@page_id_key => page.id, "revision" => page.content_revision}

  @doc "Queues indexing for the page's current revision."
  @spec enqueue_page(Page.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, Errors.reason()}
  def enqueue_page(page, opts \\ []) do
    page
    |> page_args()
    |> new(opts)
    |> Oban.insert()
    |> Errors.result()
  end

  @impl true
  def perform(%Oban.Job{args: %{@page_id_key => page_id} = args}) do
    Indexer.index_page(page_id, Map.get(args, "revision"))
  end
end
