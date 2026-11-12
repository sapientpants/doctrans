defmodule Doctrans.Search.IndexerFenceTest do
  @moduledoc """
  Covers the fence's own failure branches.

  `Indexer`'s central claim is that every write is fenced on `content_revision`,
  and each write is a separate transaction — so the fence can miss at the status
  write, at chunking, or at a chunk row that disappeared underneath a page that is
  still current. The deletion race in `indexer_race_test.exs` drives one of those;
  these drive the rest, by injecting the competing write between the query that
  reads a revision and the one that acts on it.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Search.{Chunker, EmbeddingMocks, Indexer}

  test "cancels when the revision moves between reading the page and claiming it" do
    page = extracted_page_fixture("Superseded before the status write")

    # The read in `index_page/2` has returned; the first fenced write has not run.
    after_query(&(page_select?(&1) and not lock?(&1)), fn -> rewrite(page) end)

    assert {:cancel, :stale_page} = Indexer.index_page(page.id)

    current = Repo.get!(Page, page.id)
    assert current.embedding_status == "pending"
    assert current.embedding == nil
  end

  test "cancels when the revision moves between claiming the page and chunking it" do
    page = extracted_page_fixture("Superseded before chunking")

    # The status write has committed; the fence around `ensure_chunks/1` has not run.
    after_query(&page_update?/1, fn -> rewrite(page) end)

    assert {:cancel, :stale_page} = Indexer.index_page(page.id)

    # Nothing was written for the revision that went away.
    assert Repo.get!(Page, page.id).embedding == nil
    assert page_chunks(page) == []
  end

  test "rebuilds chunks that no longer match the page's text" do
    page = extracted_page_fixture("The text the chunks should match")

    # A chunk row left behind by an older chunking algorithm: same revision, so
    # the fence passes, but the stored content is not what the page now yields.
    Repo.insert!(
      Chunk.changeset(%Chunk{page_id: page.id}, %{
        chunk_index: 0,
        content: "Stale chunk content",
        start_offset: 0,
        end_offset: 19,
        word_count: 3
      })
    )

    assert :ok = Indexer.index_page(page.id)

    assert [%Chunk{content: "The text the chunks should match", embedding_status: "completed"}] =
             page_chunks(page)
  end

  test "treats a chunk deleted under a current page as nothing left to write" do
    text = "Chunk removed mid-embedding"
    page = extracted_page_fixture(text)
    barrier = EmbeddingMocks.hold(text)

    run =
      Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
        Indexer.index_page(page.id, page.content_revision)
      end)

    assert_receive {:embedding_started, ^barrier, task}, 5_000

    # The page stays current, so the page fence passes and the chunk write is the
    # one with nothing to update — the `Ecto.StaleEntryError` path.
    assert {1, _} = Chunk |> where([c], c.page_id == ^page.id) |> Repo.delete_all()
    send(task, {:continue_embedding, barrier})

    # The page-level call follows, and its own fence still passes.
    assert_receive {:embedding_started, ^barrier, ^task}, 5_000
    send(task, {:continue_embedding, barrier})

    assert {:ok, :ok} = Task.yield(run, 5_000)

    # The run reports success for the page it did index, and the deleted chunk
    # was not resurrected.
    assert Repo.get!(Page, page.id).embedding_status == "completed"
    assert page_chunks(page) == []
  end

  test "skips a chunk deleted before its own write without failing the page" do
    markdown = multi_chunk_markdown()
    page = extracted_page_fixture(markdown)

    # Hold the run on the first chunk; the others have not been written yet.
    first = markdown |> Chunker.chunk() |> Chunker.content_for_embedding(0)
    barrier = EmbeddingMocks.hold(first)

    run =
      Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
        Indexer.index_page(page.id, page.content_revision)
      end)

    assert_receive {:embedding_started, ^barrier, task}, 5_000

    # Drop a chunk this run still intends to embed. The page is untouched, so the
    # page fence passes and only that chunk's write has nothing to update.
    assert {1, _} =
             Chunk
             |> where([c], c.page_id == ^page.id and c.chunk_index == 1)
             |> Repo.delete_all()

    send(task, {:continue_embedding, barrier})
    assert {:ok, :ok} = Task.yield(run, 5_000)

    # The missing chunk is not counted as a failure: the page still completes,
    # and every chunk that survived carries a vector.
    assert Repo.get!(Page, page.id).embedding_status == "completed"
    assert [%Chunk{chunk_index: 0}, %Chunk{chunk_index: 2}] = page_chunks(page)
    assert Enum.all?(page_chunks(page), &(&1.embedding_status == "completed"))
  end

  # A bulk update advances `content_revision` through the database trigger, which
  # is exactly what a re-extraction does to a run already in flight.
  defp rewrite(page) do
    Page
    |> where([p], p.id == ^page.id)
    |> Repo.update_all(set: [original_markdown: "Rewritten underneath the run"])
  end

  defp page_select?(query), do: String.contains?(query, ~s|FROM "pages"|)
  defp page_update?(query), do: String.contains?(query, ~s|UPDATE "pages"|)
  defp lock?(query), do: String.contains?(query, "FOR UPDATE")

  # Fires `callback` once, after the first query matching `predicate` returns.
  defp after_query(predicate, callback) do
    handler = {__MODULE__, make_ref()}
    Process.put(handler, {predicate, callback})
    :telemetry.attach(handler, [:doctrans, :repo, :query], &__MODULE__.handle_query/4, handler)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_query(_event, _measurements, metadata, handler) do
    case Process.get(handler) do
      {predicate, callback} ->
        if predicate.(metadata.query) do
          Process.delete(handler)
          callback.()
        end

      nil ->
        :ok
    end
  end
end
