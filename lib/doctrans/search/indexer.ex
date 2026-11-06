defmodule Doctrans.Search.Indexer do
  @moduledoc """
  Chunks and embeds one page revision.

  The unit of indexing is a page at a `content_revision`. Every write is fenced
  by `Doctrans.Documents.Revision.with_page/2`, so a call that started before
  the page changed cannot write vectors for text that is no longer there; a
  fence refusal is reported as `{:cancel, :stale_page}`. The page's embedding
  stage moves through `Doctrans.Documents.PageLifecycle`, which fences and
  announces it; the chunk rows are this module's own and are fenced here.

  This module adds no retry loop of its own: a transient failure is reported to
  the caller — `Doctrans.Jobs.EmbeddingJob`, which owns the retry schedule — and
  work that no longer applies is reported as `{:cancel, reason}` so it is not
  retried at all. The OpenAI client underneath still replays transient failures
  within a single call (`retry: :transient`) and owns the `:embedding_api` fuse
  outright -- it asks before the request and melts on failure -- so nothing here
  touches the circuit breaker.
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Deps
  alias Doctrans.Documents.{Chunk, Page, PageLifecycle, Revision}
  alias Doctrans.Errors
  alias Doctrans.Repo
  alias Doctrans.Resilience.ErrorClassifier
  alias Doctrans.Search.Chunker

  @typedoc "What the caller should do next: nothing, retry, or stop retrying."
  @type outcome :: :ok | {:error, Errors.reason()} | {:cancel, Errors.reason()}

  @doc """
  Indexes the page at `revision`: chunks its source text and embeds each chunk.

  Passing `nil` for `revision` indexes whatever revision the page currently holds.
  Returns `{:cancel, reason}` when the request no longer applies — the page is
  gone, its extraction is not complete, or a newer revision has superseded the
  requested one.
  """
  @spec index_page(Ecto.UUID.t(), integer() | nil) :: outcome()
  def index_page(page_id, revision \\ nil) do
    case Repo.get(Page, page_id) do
      nil ->
        Logger.debug("Indexing requested for deleted page #{page_id}; skipping")
        {:cancel, :page_not_found}

      page ->
        index_current(page, revision)
    end
  end

  defp index_current(page, revision) do
    cond do
      not is_nil(revision) and not Revision.current?(page, revision: revision) ->
        Logger.debug("Page #{page.id} moved past revision #{revision}; skipping")
        {:cancel, {:obsolete_revision, [requested: revision, current: page.content_revision]}}

      page.extraction_status != "completed" ->
        Logger.debug("Skipping indexing for page #{page.id} - extraction not completed")
        {:cancel, :extraction_incomplete}

      true ->
        start_page_embedding(page)
    end
  end

  defp start_page_embedding(page) do
    case PageLifecycle.begin(page, :embedding) do
      {:error, :obsolete_run} -> stale(page)
      {:ok, page} -> embed_page_chunks(page)
    end
  end

  # Everything below runs with the page already marked "processing". An
  # unexpected raise -- malformed text reaching a Unicode regex in `Chunker`, a
  # database blip mid-run -- would otherwise leave that status behind for good:
  # none of the paths below mark the page errored, Oban retries the job, a
  # deterministic failure raises again on every attempt, and the page is
  # discarded still reading "processing". `StartupRecovery` keys on the status,
  # so it re-enqueues that page on every boot thereafter. Recording the failure
  # keeps the status truthful; re-raising leaves Oban's retry schedule to decide
  # whether the raise was transient.
  defp embed_page_chunks(page) do
    chunk_and_embed(page)
  rescue
    error ->
      Logger.error(
        "Indexing crashed for page #{page.id}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      mark_page_errored(page)
      reraise error, __STACKTRACE__
  end

  defp chunk_and_embed(page) do
    case Revision.with_page(page, &ensure_chunks/1) do
      {:error, :obsolete_run} ->
        stale(page)

      {[], _chunk_data} ->
        Logger.info("No chunks to embed for page #{page.id} (empty content)")
        finish_page_embedding([], page, 0, 0)

      {chunks, chunk_data} ->
        # Chunks already carrying a vector are left alone, so a retry costs only
        # the chunks that have not been embedded yet.
        pending = Enum.reject(chunks, & &1.embedding)

        pending
        |> Enum.map(fn chunk ->
          embed_chunk(chunk, Chunker.content_for_embedding(chunk_data, chunk.chunk_index), page)
        end)
        |> finish_page_embedding(page, length(pending), length(chunks))
    end
  end

  # A revision that moved on has its own indexing request; this one has no work left.
  defp stale(page) do
    Logger.debug("Page #{page.id} changed during indexing; skipping")
    {:cancel, :stale_page}
  end

  defp finish_page_embedding(results, page, attempted, total) do
    case Enum.flat_map(results, fn
           {:error, reason} -> [reason]
           _ok -> []
         end) do
      [] ->
        finish_page_level_embedding(page, attempted, total)

      reasons ->
        Logger.error(
          "#{length(reasons)}/#{attempted} chunk embeddings failed for page #{page.id}"
        )

        mark_page_errored(page)
        retry_or_cancel(reasons)
    end
  end

  # The page-level vector is what global semantic search ranks on
  # (`Doctrans.Search` requires `p.embedding IS NOT NULL`), so losing it is not a
  # detail to log past: a page marked "completed" without one would be silently
  # absent from search and would never be picked up again by startup recovery,
  # which keys on the status. Reporting the failure keeps the page recoverable.
  defp finish_page_level_embedding(page, attempted, total) do
    case embed(page.original_markdown) do
      {:ok, embedding} ->
        mark_page_indexed(page, embedding, attempted, total)

      {:error, reason} ->
        Logger.error("Page-level embedding failed for page #{page.id}: #{inspect(reason)}")
        mark_page_errored(page)
        retry_or_cancel([reason])
    end
  end

  # The vector and the status land in one transition, so "completed" implies a
  # page vector by construction rather than by two writes happening to both
  # succeed. A page that changed or was deleted while its chunks were embedding
  # reports the run as superseded rather than as a completed index it never
  # wrote.
  defp mark_page_indexed(page, embedding, attempted, total) do
    case PageLifecycle.complete(page, :embedding, %{embedding: embedding}) do
      {:error, :obsolete_run} ->
        stale(page)

      {:ok, _indexed} ->
        Logger.info("Indexed #{attempted} of #{total} chunks on page #{page.id}")
        :ok
    end
  end

  defp mark_page_errored(page) do
    _ = PageLifecycle.fail(page, :embedding)
    :ok
  end

  # A page is given up on only when *every* failure on it is permanent. One
  # oversized chunk must not strand the chunks that failed transiently beside it,
  # which is what classifying on the first failure alone used to do.
  defp retry_or_cancel([_ | _] = reasons) do
    reasons = Enum.map(reasons, &Errors.normalize/1)

    case Enum.find(reasons, &ErrorClassifier.retryable?/1) do
      nil -> {:cancel, hd(reasons)}
      retryable -> {:error, retryable}
    end
  end

  # Chunking is the one place the page's text is split, and the result is carried
  # through to embedding rather than recomputed per caller.
  defp ensure_chunks(page) do
    chunk_data = Chunker.chunk(page.original_markdown)

    existing =
      Chunk
      |> where([c], c.page_id == ^page.id)
      |> order_by([c], c.chunk_index)
      |> Repo.all()

    cond do
      existing == [] ->
        {create_chunks(page.id, chunk_data), chunk_data}

      chunks_match_page_content?(existing, chunk_data) ->
        {existing, chunk_data}

      true ->
        {recreate_chunks(page.id, chunk_data), chunk_data}
    end
  end

  defp chunks_match_page_content?(existing_chunks, chunk_data) do
    current = Enum.map(chunk_data, &%{chunk_index: &1.chunk_index, content: &1.content})
    stored = Enum.map(existing_chunks, &%{chunk_index: &1.chunk_index, content: &1.content})

    current == stored
  end

  defp create_chunks(page_id, chunk_data) do
    # Source and translation boundaries are not aligned. Store source chunks only.
    Enum.each(chunk_data, fn data ->
      %Chunk{page_id: page_id}
      |> Chunk.changeset(data)
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:page_id, :chunk_index]
      )
    end)

    # Re-fetch to get actual records (on_conflict: :nothing may return empty struct)
    Chunk
    |> where([c], c.page_id == ^page_id)
    |> order_by([c], c.chunk_index)
    |> Repo.all()
  end

  # Only reached from `ensure_chunks/1`, which holds the page lock — the delete
  # and the re-insert must not be visible to another run as an empty page.
  defp recreate_chunks(page_id, chunk_data) do
    Chunk |> where([c], c.page_id == ^page_id) |> Repo.delete_all()
    create_chunks(page_id, chunk_data)
  end

  defp embed_chunk(chunk, embed_content, page) do
    case fenced_update(Chunk.embedding_changeset(chunk, %{embedding_status: "processing"}), page) do
      {:error, :obsolete_run} ->
        # Either the page moved to a new revision or this chunk row is gone.
        # Either way there is nothing left to embed, and the fenced page-level
        # write in `mark_page_indexed/3` sees the same staleness and reports the
        # run as superseded — so this is not a failure to count against the page.
        Logger.debug("Chunk #{chunk.id} is no longer current; skipping")
        {:ok, chunk.id}

      {:ok, chunk} ->
        embed_current_chunk(chunk, embed_content, page)
    end
  end

  defp embed_current_chunk(chunk, embed_content, page) do
    case embed(embed_content) do
      {:ok, embedding} ->
        _ =
          fenced_update(
            Chunk.embedding_changeset(chunk, %{
              embedding: embedding,
              embedding_status: "completed"
            }),
            page
          )

        {:ok, chunk.id}

      {:error, reason} ->
        Logger.warning("Embedding failed for chunk #{chunk.id}: #{inspect(reason)}")
        _ = fenced_update(Chunk.embedding_changeset(chunk, %{embedding_status: "error"}), page)
        {:error, reason}
    end
  end

  defp embed(content), do: Deps.embedding().generate(content, [])

  # `Repo.update!` raises `Ecto.StaleEntryError` when the row it targets is gone
  # by the time the UPDATE runs. The fence holds the page, so in practice this
  # is a chunk row deleted under a still-current page. Nothing was written, and
  # there is nothing left to write: it is reported like any other refusal.
  defp fenced_update(changeset, page) do
    Revision.with_page(page, fn _current -> {:ok, Repo.update!(changeset)} end)
  rescue
    Ecto.StaleEntryError -> {:error, :obsolete_run}
  end
end
