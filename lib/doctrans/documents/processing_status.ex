defmodule Doctrans.Documents.ProcessingStatus do
  @moduledoc """
  A document's processing and indexing state, reported separately.

  Content and indexing are two pipelines with two outcomes: a fully translated
  document can still be unindexed, and a document whose indexing is ready can
  still have a failed page. Collapsing them into one badge hides whichever is
  the problem, so this struct carries both, plus the counts behind them and,
  for every action a user can take, whether it is offered right now or why it
  is withheld.

  The actions are the one statement of those rules. The viewer renders a
  control from the answer and names the refusal on a disabled one; the
  transactions in `Doctrans.Processing.DocumentReprocessing` ask the same
  question under the document lock and roll back with the same reason, so a
  control and the transaction behind it cannot disagree. A refusal is the atom
  the transaction would answer with, which `DoctransWeb.ErrorMessages` already
  renders.

  The document row is authoritative for terminal states (`completed`,
  `cancelled`, `error`) and Oban for live ones: only the row survives a restart,
  and only the queue knows whether an errored document still has a retry coming.

  Reads only. Nothing here enqueues or writes.
  """

  import Ecto.Query
  import Doctrans.Documents.Page, only: [failed?: 1, settled?: 1]

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Lifecycle, Page, Progress}
  alias Doctrans.Processing.{JobStates, Run}
  alias Doctrans.Repo

  @in_flight [:running, :queued, :retrying]

  @type content :: :idle | :queued | :running | :retrying | :failed | :completed | :cancelled
  @type index :: :none | :queued | :running | :retrying | :pending | :partial | :failed | :ready

  @typedoc "Whether an action is offered right now, or the reason it is withheld."
  @type offer :: :offered | {:refused, atom()}

  @typedoc """
  The actions a user can take on a document. `reprocess_page` is the
  document-level answer for any of its pages; `reprocess_page/2` adds the page.
  """
  @type actions :: %{
          retry_pages: offer(),
          retry_index: offer(),
          cancel: offer(),
          reprocess_document: offer(),
          reprocess_page: offer()
        }

  @enforce_keys [
    :document_id,
    :content,
    :index,
    :progress,
    :failed_pages,
    :failed_page_count,
    :pages,
    :indexing,
    :source_available?,
    :actions
  ]
  defstruct [
    :document_id,
    :content,
    :index,
    :progress,
    :failed_pages,
    :failed_page_count,
    :pages,
    :indexing,
    :source_available?,
    :actions
  ]

  @type t :: %__MODULE__{
          document_id: Ecto.UUID.t(),
          content: content(),
          index: index(),
          progress: float(),
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
          source_available?: boolean(),
          actions: actions()
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
    source_available? = Run.source_available?(document)

    %__MODULE__{
      document_id: document.id,
      content: content,
      index: index,
      # The same arithmetic the dashboard card runs over its loaded pages, fed
      # from this query instead: `indexable` is the count of completed
      # extractions, which is also the first of the two steps progress counts.
      progress: Progress.from_counts(counts.indexable, counts.translated, document.total_pages),
      failed_pages: Documents.failed_page_numbers(document.id),
      # Derived, never recounted: a second definition of failure is a second
      # answer, and the badge and the list would eventually disagree.
      failed_page_count: pages.failed,
      pages: pages,
      indexing: indexing,
      source_available?: source_available?,
      actions: actions(document, activity, pages, indexing, source_available?)
    }
  end

  @doc """
  Whether reprocessing `page` is offered: the document-level answer, or
  `{:refused, :page_not_found}` when there is no page.
  """
  @spec reprocess_page(t(), Page.t() | nil) :: offer()
  def reprocess_page(%__MODULE__{}, nil), do: {:refused, :page_not_found}
  def reprocess_page(%__MODULE__{actions: actions}, %Page{}), do: actions.reprocess_page

  # The rules are read from the raw job activity, not from the display states
  # above it: those put a terminal verdict ahead of a job, so a completed
  # document with a straggling job reads `completed`, but the straggler is
  # still work in flight that a retry or a fresh run must not race. The
  # refusals are ordered as the transactions order theirs.
  defp actions(document, activity, pages, indexing, source_available?) do
    # An extraction or page job is queued, retrying or running.
    working? = activity.content != :idle
    page_work = offer_page_work(document, working?)

    %{
      retry_pages: offer_retry_pages(page_work, pages),
      retry_index: offer_retry_index(activity.index, indexing),
      cancel: offer(Lifecycle.cancellable?(document), :not_cancellable),
      reprocess_document: offer_reprocess_document(document, working?, source_available?),
      reprocess_page: page_work
    }
  end

  # Per-page work can replace or retry a page only once the run has produced
  # its pages and nothing is still working on them: re-queueing a page whose
  # job is executing duplicates the model call and the write behind it.
  defp offer_page_work(document, working?),
    do: offer(not Lifecycle.pre_processing?(document) and not working?, :already_processing)

  defp offer_retry_pages(:offered, pages), do: offer(pages.failed > 0, :nothing_to_retry)
  defp offer_retry_pages(refused, _pages), do: refused

  defp offer_retry_index(index_activity, indexing) do
    cond do
      index_activity != :idle -> {:refused, :already_processing}
      indexing.outstanding == 0 -> {:refused, :nothing_to_retry}
      true -> :offered
    end
  end

  # A fresh run replaces a settled one; the original upload has to be on disk
  # for it to render from.
  defp offer_reprocess_document(document, working?, source_available?) do
    cond do
      not Lifecycle.reprocessable?(document) or working? -> {:refused, :already_processing}
      not source_available? -> {:refused, :original_upload_missing}
      true -> :offered
    end
  end

  defp offer(true, _refusal), do: :offered
  defp offer(false, refusal), do: {:refused, refusal}

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

  # The terminal verdicts are the row's alone. Below them, a live job outranks
  # the row: a document recorded as failed has finished failing only once
  # nothing is left running for it, and while a job of its own is queued,
  # executing or waiting on a retry, that job is what the document is doing --
  # saying `failed` instead would offer a retry that the actions above withhold
  # anyway. With nothing running, an in-progress document is genuinely idle:
  # that gap is what startup recovery exists to repair, so it must not be
  # dressed up as running. Before any page job exists there is nothing to be
  # idle about yet, so the pre-page statuses read as queued instead.
  defp content_state(document, activity) do
    cond do
      Lifecycle.completed?(document) -> :completed
      Lifecycle.cancelled?(document) -> :cancelled
      activity != :idle -> activity
      Lifecycle.failed?(document) -> :failed
      Lifecycle.pre_processing?(document) -> :queued
      true -> :idle
    end
  end

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
