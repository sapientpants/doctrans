defmodule Doctrans.Search.Indexer do
  @moduledoc """
  Chunks and embeds one page revision.

  The unit of indexing is a page at a `content_revision`. Every write is fenced on
  that revision, so a call that started before the page changed cannot write
  vectors for text that is no longer there.

  Nothing here retries or sleeps. A transient failure is reported to the caller —
  `Doctrans.Jobs.EmbeddingJob`, which owns the retry schedule — and work that no
  longer applies is reported as `{:cancel, reason}` so it is not retried at all.
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Errors
  alias Doctrans.Repo
  alias Doctrans.Resilience.{CircuitBreaker, ErrorClassifier}
  alias Doctrans.Search.Chunker

  @typedoc "What the caller should do next: nothing, retry, or stop retrying."
  @type outcome :: :ok | {:error, Errors.reason()} | {:cancel, Errors.reason()}

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end

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
      not is_nil(revision) and page.content_revision != revision ->
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
    case fenced_update(Page.embedding_changeset(page, %{embedding_status: "processing"}), page) do
      {:error, :stale_entry} -> stale(page)
      {:ok, page} -> embed_page_chunks(page)
    end
  end

  defp embed_page_chunks(page) do
    case with_current_revision(page, &ensure_chunks/1) do
      {:error, :stale_entry} ->
        stale(page)

      {:ok, []} ->
        Logger.info("No chunks to embed for page #{page.id} (empty content)")
        mark_page_indexed(page, 0)

      {:ok, chunks} ->
        chunks
        |> embed_pending(page)
        |> finish_page_embedding(page, length(chunks))
    end
  end

  # A revision that moved on has its own indexing request; this one has no work left.
  defp stale(page) do
    Logger.debug("Page #{page.id} changed during indexing; skipping")
    {:cancel, :stale_page}
  end

  # Chunks already carrying a vector are left alone, so a retry costs only the
  # chunks that have not been embedded yet.
  defp embed_pending(chunks, page) do
    chunk_data = Chunker.chunk(page.original_markdown)

    chunks
    |> Enum.reject(& &1.embedding)
    |> Enum.map(fn chunk ->
      embed_chunk(chunk, Chunker.content_for_embedding(chunk_data, chunk.chunk_index), page)
    end)
  end

  defp finish_page_embedding(results, page, chunk_count) do
    case Enum.filter(results, &match?({:error, _}, &1)) do
      [] ->
        # Page-level failure is only logged; see PLAN.md R02.
        _ = generate_page_embedding(page)
        mark_page_indexed(page, chunk_count)

      [{:error, reason} | _] = failures ->
        Logger.error(
          "#{length(failures)}/#{chunk_count} chunk embeddings failed for page #{page.id}"
        )

        _ = fenced_update(Page.embedding_changeset(page, %{embedding_status: "error"}), page)
        retry_or_cancel(reason)
    end
  end

  # The final write is fenced like every other one, so a page that changed or was
  # deleted while its chunks were embedding reports the run as superseded rather
  # than as a completed index it never wrote.
  defp mark_page_indexed(page, chunk_count) do
    case fenced_update(Page.embedding_changeset(page, %{embedding_status: "completed"}), page) do
      {:error, :stale_entry} ->
        stale(page)

      {:ok, _page} ->
        Logger.info("Indexed #{chunk_count} chunks on page #{page.id}")
        :ok
    end
  end

  defp retry_or_cancel(reason) do
    if ErrorClassifier.retryable?(reason),
      do: {:error, Errors.normalize(reason)},
      else: {:cancel, Errors.normalize(reason)}
  end

  defp ensure_chunks(page) do
    existing =
      Chunk
      |> where([c], c.page_id == ^page.id)
      |> order_by([c], c.chunk_index)
      |> Repo.all()

    cond do
      existing == [] ->
        create_chunks(page)

      chunks_match_page_content?(existing, page.original_markdown) ->
        existing

      true ->
        recreate_chunks(page.id)
    end
  end

  defp chunks_match_page_content?(existing_chunks, original_markdown) do
    current_chunk_data =
      original_markdown
      |> Chunker.chunk()
      |> Enum.map(fn data ->
        %{chunk_index: data.chunk_index, content: data.content}
      end)

    existing_chunk_data =
      Enum.map(existing_chunks, fn chunk ->
        %{chunk_index: chunk.chunk_index, content: chunk.content}
      end)

    current_chunk_data == existing_chunk_data
  end

  defp create_chunks(page) do
    chunk_data = Chunker.chunk(page.original_markdown)

    # Source and translation boundaries are not aligned. Store source chunks only.
    Enum.each(chunk_data, fn data ->
      %Chunk{page_id: page.id}
      |> Chunk.changeset(data)
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:page_id, :chunk_index]
      )
    end)

    # Re-fetch to get actual records (on_conflict: :nothing may return empty struct)
    Chunk
    |> where([c], c.page_id == ^page.id)
    |> order_by([c], c.chunk_index)
    |> Repo.all()
  end

  @doc """
  Recreates chunks for a page, deleting any existing ones.
  Used when page content changes (e.g., re-extraction).
  """
  @spec recreate_chunks(Ecto.UUID.t()) :: [Chunk.t()]
  def recreate_chunks(page_id) do
    Chunk |> where([c], c.page_id == ^page_id) |> Repo.delete_all()
    page = Repo.get!(Page, page_id)
    create_chunks(page)
  end

  defp embed_chunk(chunk, embed_content, page) do
    case fenced_update(Chunk.embedding_changeset(chunk, %{embedding_status: "processing"}), page) do
      {:error, :stale_entry} ->
        # The page-level write below is fenced too, so letting the caller finish
        # costs one no-op update and keeps the failure count honest.
        Logger.debug("Chunk #{chunk.id} was deleted before embedding; skipping")
        {:ok, chunk.id}

      {:ok, chunk} ->
        embed_current_chunk(chunk, embed_content, page)
    end
  end

  defp embed_current_chunk(chunk, embed_content, page) do
    result =
      CircuitBreaker.call(:embedding_api, fn ->
        embedding_module().generate(embed_content, [])
      end)

    case result do
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

  defp generate_page_embedding(page) do
    result =
      CircuitBreaker.call(:embedding_api, fn ->
        embedding_module().generate(page.original_markdown, [])
      end)

    case result do
      {:ok, embedding} ->
        _ = fenced_update(Page.embedding_changeset(page, %{embedding: embedding}), page)

      {:error, reason} ->
        Logger.warning("Page-level embedding failed for page #{page.id}: #{inspect(reason)}")
    end
  end

  # `Repo.update!` raises `Ecto.StaleEntryError` when the row is deleted while
  # indexing is in flight (e.g. the user removes the document mid-embedding). The
  # row is gone, so there is nothing to update — treat it as a no-op.
  defp fenced_update(changeset, page) do
    with_current_revision(page, fn _current -> Repo.update!(changeset) end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Serialize writes with content invalidation, without holding a lock during API calls.
  defp with_current_revision(page, fun) do
    Repo.transaction(fn ->
      current = Repo.one(from p in Page, where: p.id == ^page.id, lock: "FOR UPDATE")

      if current && current.content_revision == page.content_revision &&
           current.extraction_status == "completed" do
        fun.(current)
      else
        Repo.rollback(:stale_entry)
      end
    end)
  end
end
