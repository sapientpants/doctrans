defmodule Doctrans.Search.Reindex do
  @moduledoc """
  Re-queues indexing for pages, and nothing else.

  Translation is not rerun. The pages keep their extracted and translated
  markdown, their content revision and their processing generation, so a
  document that translated successfully and failed to index is recovered without
  paying again for the work that succeeded. Repeating the indexing itself is
  cheap by design: `Doctrans.Search.Indexer` embeds only the chunks that still
  lack a vector.

  Two entry points share that machinery. `retry_document/1` finishes an index
  that failed, and touches nothing a page already has. `rebuild_page/1` throws a
  page's index away first, because the Indexer's economy — keeping every chunk
  that already carries a vector — is exactly what stands between a page and a
  rebuild after the chunker or the embedding model changed. Neither calls a
  model: both queue `Doctrans.Jobs.EmbeddingJob`, so every vector is written by
  the one path that fences its writes on the page revision.

  This is also the only way back for a revision whose indexing job was
  `cancelled`. `Doctrans.Processing.StartupRecovery` reads a cancelled job as
  that revision's verdict and deliberately refuses to re-queue it on every boot,
  and `Doctrans.Jobs.EmbeddingJob` keys uniqueness over the active states alone,
  so a `cancelled`, `discarded` or `completed` job does not stand in the way of
  the insert made here.
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Documents.{Chunk, Document, Page}
  alias Doctrans.Errors
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Repo

  @doc """
  Queues indexing for every page of the document that is extracted but not indexed.

  Returns how many pages were queued. A page an active indexing job already owns
  is that job's to finish and is not counted.
  """
  @spec retry_document(Document.t() | Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, Errors.reason()}
  def retry_document(%Document{} = document), do: retry_document(document.id)

  def retry_document(document_id) do
    case Repo.get(Document, document_id) do
      nil -> {:error, :document_not_found}
      document -> {:ok, queue_unindexed_pages(document.id)}
    end
  end

  # The predicate `Doctrans.Processing.StartupRecovery` recovers on, narrowed to
  # one document: extraction is what indexing reads, so a page without it has
  # nothing to index yet.
  defp queue_unindexed_pages(document_id) do
    from(p in Page,
      where: p.document_id == ^document_id,
      where: p.extraction_status == "completed",
      where: p.embedding_status != "completed",
      order_by: p.page_number,
      select: %{id: p.id}
    )
    |> Repo.all()
    |> Enum.count(&queue_page/1)
  end

  # One page per transaction: the rows are independent, so a page that cannot be
  # queued costs that page rather than the batch, and the lock below is held
  # across one insert instead of the whole document.
  #
  # The predicate is re-read under that lock, so a page rewritten since it was
  # selected is queued at the revision it now holds rather than one the job
  # would cancel on.
  defp queue_page(row) do
    Repo.transact(fn ->
      case lock_page(row.id) do
        %Page{extraction_status: "completed", embedding_status: status} = page
        when status != "completed" ->
          queue_locked_page(page)

        _ ->
          {:ok, false}
      end
    end)
    |> case do
      {:ok, queued?} -> queued?
      {:error, reason} -> skip_page(row.id, reason)
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      skip_page(row.id, error)
  end

  defp lock_page(page_id) do
    from(p in Page, where: p.id == ^page_id, lock: "FOR UPDATE") |> Repo.one()
  end

  # Insert before writing the status: uniqueness also covers a job queued since
  # selection, and a conflicting job already owns this page's revision, so the
  # stored failure is that job's to clear rather than this call's.
  defp queue_locked_page(page) do
    case EmbeddingJob.enqueue_page(page) do
      {:ok, %Oban.Job{conflict?: true}} -> {:ok, false}
      {:ok, %Oban.Job{}} -> {:ok, clear_failure(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A stored `error` would go on reporting a failure that is being retried, and
  # would keep drawing the viewer to a recovery already under way. Only the
  # indexing status moves: every field the translation produced is left alone.
  defp clear_failure(%Page{embedding_status: "error"} = page) do
    _ = page |> Page.embedding_changeset(%{embedding_status: "pending"}) |> Repo.update!()
    true
  end

  defp clear_failure(_page), do: true

  defp skip_page(page_id, reason) do
    Logger.warning("Reindex could not queue indexing for page #{page_id}: #{inspect(reason)}")
    false
  end

  @doc """
  Ids of every page with extracted text, in library order: the pages a rebuild
  of the whole library goes through.
  """
  @spec extracted_page_ids() :: [Ecto.UUID.t()]
  def extracted_page_ids do
    from(p in Page,
      where: p.extraction_status == "completed",
      where: not is_nil(p.original_markdown),
      order_by: [p.document_id, p.page_number],
      select: p.id
    )
    |> Repo.all()
  end

  @doc """
  Clears the page's index and queues it for indexing from scratch.

  Under the page lock, the page's chunks are deleted, its page-level vector is
  dropped and its status returns to `pending`, then the current revision is
  queued. The reset is what makes this a rebuild rather than a retry: the
  Indexer alone would keep every chunk that already has a vector, and so would
  re-embed nothing on a page whose text has not changed.

  The reset is rolled back when an active indexing job already owns the page's
  revision — that job is mid-run on the index this call would have deleted from
  under it, and its own fenced writes would then mark the page complete with
  no chunks behind it. Such a page is reported as `{:skipped,
  :indexing_in_progress}` and is left exactly as it was; call again once the job
  has finished. The content revision is not touched: chat keeps saved context by
  it, and the page's text has not changed.
  """
  @spec rebuild_page(Ecto.UUID.t()) ::
          {:ok, :queued}
          | {:skipped, :indexing_in_progress | :not_extracted | :page_not_found}
          | {:error, Errors.reason()}
  def rebuild_page(page_id) do
    Repo.transact(fn ->
      case lock_page(page_id) do
        %Page{extraction_status: "completed"} = page -> rebuild_locked_page(page)
        %Page{} -> {:error, {:skipped, :not_extracted}}
        nil -> {:error, {:skipped, :page_not_found}}
      end
    end)
    |> case do
      {:ok, :queued} -> {:ok, :queued}
      {:error, {:skipped, reason}} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, Errors.normalize(error)}
  end

  # Reset before inserting, so that a conflict — which is only known once the
  # insert has run — ends in a rollback that leaves the page untouched, rather
  # than in a reset the owning job is not expecting. The order also keeps an
  # inline job (Oban's `:inline` testing mode runs it inside this insert) from
  # indexing the chunks the reset is about to delete.
  defp rebuild_locked_page(page) do
    page = reset_index(page)

    case EmbeddingJob.enqueue_page(page) do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, {:skipped, :indexing_in_progress}}
      {:ok, %Oban.Job{}} -> {:ok, :queued}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only valid under the page lock: a delete-then-recreate must never be visible
  # to a concurrent indexing run as an empty page (see `Indexer.recreate_chunks/2`).
  defp reset_index(page) do
    _ = Chunk |> where([c], c.page_id == ^page.id) |> Repo.delete_all()

    page
    |> Page.embedding_changeset(%{embedding: nil, embedding_status: "pending"})
    |> Repo.update!()
  end
end
