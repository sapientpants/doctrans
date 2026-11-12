defmodule Doctrans.Search.ReindexRebuildTest do
  @moduledoc """
  `Reindex.rebuild_page/1` is a locked reset followed by a queued indexing run.

  The reset is the point: `Doctrans.Search.Indexer` keeps every chunk that
  already carries a vector, so without it a page whose text has not changed
  would be re-indexed into exactly the index it had. The conflict case is the
  other claim worth pinning — an owned page must come out untouched, not half
  reset.
  """
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents.Page
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Search.{Chunker, Indexer, Reindex}

  test "clears the page's index under the lock and queues its current revision" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      page = indexed_page()
      assert [_ | _] = page_chunks(page)

      assert {:ok, :queued} = Reindex.rebuild_page(page.id)

      assert page_chunks(page) == []
      reloaded = Repo.get!(Page, page.id)
      assert reloaded.embedding == nil
      assert reloaded.embedding_status == "pending"
      assert reloaded.content_revision == page.content_revision

      assert [job] = all_enqueued(worker: EmbeddingJob)
      assert job.args["page_id"] == page.id
      assert job.args["revision"] == page.content_revision
    end)
  end

  test "the queued run re-embeds every chunk, which indexing alone would have skipped" do
    page = indexed_page()
    before = page_chunks(page)

    # Indexing alone keeps the vectors it finds: the chunk rows survive as they are.
    assert :ok = Indexer.index_page(page.id)
    assert Enum.map(page_chunks(page), & &1.id) == Enum.map(before, & &1.id)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, :queued} = Reindex.rebuild_page(page.id)
      assert [job] = all_enqueued(worker: EmbeddingJob)
      assert :ok = perform_job(EmbeddingJob, job.args)
    end)

    rebuilt = page_chunks(page)
    refute Enum.any?(rebuilt, &(&1.id in Enum.map(before, fn c -> c.id end)))

    assert Enum.map(rebuilt, & &1.content) ==
             Enum.map(Chunker.chunk(page.original_markdown), & &1.content)

    assert Enum.all?(rebuilt, &(&1.embedding_status == "completed" and &1.embedding != nil))

    reloaded = Repo.get!(Page, page.id)
    assert reloaded.embedding_status == "completed"
    assert reloaded.embedding != nil
  end

  test "leaves a page an active indexing job already owns exactly as it was" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      page = indexed_page()
      before = page_chunks(page)
      assert {:ok, _job} = EmbeddingJob.enqueue_page(page)

      assert {:skipped, :indexing_in_progress} = Reindex.rebuild_page(page.id)

      assert page_chunks(page) == before
      reloaded = Repo.get!(Page, page.id)
      assert reloaded.embedding_status == "completed"
      assert reloaded.embedding == page.embedding
      assert length(all_enqueued(worker: EmbeddingJob)) == 1
    end)
  end

  test "skips a page whose extraction never completed, and an unknown page" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      page = page_fixture(document_fixture(), %{extraction_status: "error"})

      assert {:skipped, :not_extracted} = Reindex.rebuild_page(page.id)
      assert {:skipped, :page_not_found} = Reindex.rebuild_page(Ecto.UUID.generate())
      assert all_enqueued(worker: EmbeddingJob) == []
    end)
  end

  test "extracted_page_ids/0 lists only pages with extracted text" do
    document = document_fixture()
    extracted = completed_page_fixture(document, %{page_number: 1})
    _pending = page_fixture(document, %{page_number: 2})

    _errored =
      page_fixture(document, %{
        page_number: 3,
        image_path: "documents/#{document.id}/pages/page_3.png",
        extraction_status: "error"
      })

    assert extracted.id in Reindex.extracted_page_ids()
    assert Enum.count(Reindex.extracted_page_ids(), &(&1 in page_ids_of(document))) == 1
  end

  # A page the Indexer has already fully indexed, with chunk and page vectors in place.
  defp indexed_page do
    page = completed_page_fixture(document_fixture())
    assert :ok = Indexer.index_page(page.id)
    Repo.get!(Page, page.id)
  end

  defp page_ids_of(document) do
    Page |> where([p], p.document_id == ^document.id) |> select([p], p.id) |> Repo.all()
  end
end
