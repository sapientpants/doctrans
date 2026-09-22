defmodule Doctrans.Documents.ProcessingStatus do
  @moduledoc """
  A document's processing and indexing state, reported separately.

  Content and indexing are two pipelines with two outcomes: a fully translated
  document can still be unindexed, and a document whose indexing is ready can
  still have a failed page. Collapsing them into one badge hides whichever is
  the problem, so this struct carries both, plus the counts behind them and the
  flags saying which targeted actions are safe to offer right now.

  The document row is authoritative for terminal states (`completed`,
  `cancelled`, `error`) and Oban for live ones: only the row survives a restart,
  and only the queue knows whether an errored document still has a retry coming.

  Reads only. Nothing here enqueues or writes.
  """

  import Ecto.Query
  import Doctrans.Documents.Page, only: [failed?: 1, settled?: 1]

  alias Doctrans.Documents.{Document, Page, Pages}
  alias Doctrans.Processing.JobStates
  alias Doctrans.Repo

  @active_content ~w(uploading queued extracting)
  @cancellable ~w(uploading queued extracting processing)
  @in_flight [:running, :queued, :retrying]

  @type content :: :idle | :queued | :running | :retrying | :failed | :completed | :cancelled
  @type index :: :none | :queued | :running | :retrying | :pending | :partial | :failed | :ready

  @enforce_keys [
    :document_id,
    :content,
    :index,
    :failed_pages,
    :failed_page_count,
    :pages,
    :indexing,
    :retry_pages?,
    :retry_index?,
    :cancellable?
  ]
  defstruct [
    :document_id,
    :content,
    :index,
    :failed_pages,
    :failed_page_count,
    :pages,
    :indexing,
    :retry_pages?,
    :retry_index?,
    :cancellable?
  ]

  @type t :: %__MODULE__{
          document_id: Ecto.UUID.t(),
          content: content(),
          index: index(),
          failed_pages: [integer()],
          failed_page_count: non_neg_integer(),
          pages: %{
            expected: non_neg_integer() | nil,
            translated: non_neg_integer(),
            failed: non_neg_integer(),
            outstanding: non_neg_integer()
          },
          indexing: %{
            indexable: non_neg_integer(),
            indexed: non_neg_integer(),
            failed: non_neg_integer(),
            outstanding: non_neg_integer()
          },
          retry_pages?: boolean(),
          retry_index?: boolean(),
          cancellable?: boolean()
        }

  @doc """
  Builds the status of one document from its row, its pages and its live jobs.
  """
  @spec for_document(Document.t()) :: t()
  def for_document(%Document{} = document) do
    activity = JobStates.for_document(document.id)
    counts = counts(document.id)
    pages = page_counts(document, counts)
    indexing = indexing_counts(counts)
    content = content_state(document, activity.content)
    index = index_state(activity.index, indexing)

    %__MODULE__{
      document_id: document.id,
      content: content,
      index: index,
      failed_pages: Pages.failed_page_numbers(document.id),
      # Derived, never recounted: a second definition of failure is a second
      # answer, and the badge and the list would eventually disagree.
      failed_page_count: pages.failed,
      pages: pages,
      indexing: indexing,
      # A retry must not race work already in flight: re-queueing a page whose
      # job is executing duplicates the model call and the write behind it.
      retry_pages?: pages.failed > 0 and content not in @in_flight,
      retry_index?: indexing.outstanding > 0 and index not in @in_flight,
      cancellable?: document.status in @cancellable
    }
  end

  # One pass over the pages for both pipelines. `failed?/1` and `settled?/1` are
  # the schema's own query-land predicates, imported rather than restated so
  # this read model cannot invent a third definition of a failed page.
  defp counts(document_id) do
    from(p in Page,
      where: p.document_id == ^document_id,
      select: %{
        translated: filter(count(p.id), p.translation_status == "completed"),
        failed: filter(count(p.id), failed?(p)),
        unsettled: filter(count(p.id), not settled?(p)),
        indexable: filter(count(p.id), p.extraction_status == "completed"),
        indexed:
          filter(
            count(p.id),
            p.extraction_status == "completed" and p.embedding_status == "completed"
          ),
        index_failed:
          filter(
            count(p.id),
            p.extraction_status == "completed" and p.embedding_status == "error"
          )
      }
    )
    |> Repo.one()
  end

  defp page_counts(document, counts) do
    %{
      expected: document.total_pages,
      translated: counts.translated,
      failed: counts.failed,
      outstanding: outstanding_pages(document.total_pages, counts)
    }
  end

  # Before extraction finishes there is no page count to subtract from, so the
  # rows are all there is to go on and outstanding means "exists, hasn't
  # settled". Once `total_pages` is known it is the honest denominator: pages
  # that were never created are still owed.
  defp outstanding_pages(expected, counts) when is_integer(expected) and expected > 0,
    do: max(expected - counts.translated - counts.failed, 0)

  defp outstanding_pages(_expected, counts), do: counts.unsettled

  # Only an extracted page can be indexed, which is the same predicate startup
  # recovery queues embeddings on. Failed pages stay in `outstanding` on
  # purpose: a page whose embedding errored is not indexed, and counting it as
  # anything but outstanding would report the index as more ready than it is.
  defp indexing_counts(counts) do
    %{
      indexable: counts.indexable,
      indexed: counts.indexed,
      failed: counts.index_failed,
      outstanding: counts.indexable - counts.indexed
    }
  end

  defp content_state(%{status: "completed"}, _activity), do: :completed
  defp content_state(%{status: "cancelled"}, _activity), do: :cancelled

  # A document recorded as errored has finished failing only once nothing is
  # left running for it. While a job of its own is queued, executing or waiting
  # on a retry, that job is what the document is doing, and saying `failed`
  # instead would offer a retry that `Run.active?/1` refuses anyway.
  defp content_state(%{status: "error"}, :idle), do: :failed
  defp content_state(%{status: "error"}, activity), do: activity

  # An in-progress document with no Oban job is genuinely idle — that gap is
  # what startup recovery exists to repair — so it must not be dressed up as
  # running. Before any page job exists there is nothing to be idle about yet,
  # so the pre-page statuses read as queued instead.
  defp content_state(%{status: status}, :idle) when status in @active_content, do: :queued
  defp content_state(_document, activity), do: activity

  # Nothing extracted means nothing indexable, which is a different statement
  # from "indexed nothing" and must not read as a pending index.
  defp index_state(_activity, %{indexable: 0}), do: :none

  defp index_state(activity, indexing) do
    cond do
      # A live job outranks the stored counts: those counts are a snapshot of
      # the very work the running job is about to change, so reporting
      # `partial` while an embedding executes describes an already-stale past.
      activity in @in_flight -> activity
      indexing.outstanding == 0 -> :ready
      indexing.failed > 0 -> :failed
      indexing.indexed > 0 -> :partial
      true -> :pending
    end
  end
end
