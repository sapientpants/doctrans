defmodule Doctrans.Search.ReindexTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  alias Doctrans.Documents.Page
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob}
  alias Doctrans.Search.Reindex

  @moduletag :postgres

  describe "retry_document/1" do
    test "recovers an indexing failure without rerunning a successful translation" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 2})
        indexed = page_with_embedding_status(document, 1, "completed")
        unindexed = page_with_embedding_status(document, 2, "error")
        translated = content_of([indexed, unindexed])

        assert {:ok, 1} = Reindex.retry_document(document.id)

        assert [job] = all_enqueued(worker: EmbeddingJob)
        assert job.args["page_id"] == unindexed.id
        assert job.args["revision"] == unindexed.content_revision

        # The two jobs that would redo the translation this retry exists to keep.
        assert all_enqueued(worker: LlmProcessingJob) == []
        assert all_enqueued(worker: DocumentExtractionJob) == []

        assert content_of([indexed, unindexed]) == translated
        assert Repo.get!(Page, unindexed.id).embedding_status == "pending"
      end)
    end

    test "queues every extracted page that is not indexed" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 3})
        pages = for number <- 1..3, do: page_with_embedding_status(document, number, "pending")

        assert {:ok, 3} = Reindex.retry_document(document)
        assert length(all_enqueued(worker: EmbeddingJob)) == 3

        assert Enum.sort(Enum.map(all_enqueued(worker: EmbeddingJob), & &1.args["page_id"])) ==
                 Enum.sort(Enum.map(pages, & &1.id))
      end)
    end

    test "skips pages that are already indexed" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 2})
        for number <- 1..2, do: page_with_embedding_status(document, number, "completed")

        assert {:ok, 0} = Reindex.retry_document(document.id)
        assert all_enqueued(worker: EmbeddingJob) == []
      end)
    end

    test "skips a page whose extraction never completed" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "error", total_pages: 1})
        _page = page_fixture(document, %{extraction_status: "error"})

        assert {:ok, 0} = Reindex.retry_document(document.id)
        assert all_enqueued(worker: EmbeddingJob) == []
      end)
    end

    test "returns zero for a document with nothing to index" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, 0} = Reindex.retry_document(document_fixture().id)
      end)
    end

    test "reports an unknown document" do
      assert {:error, :document_not_found} = Reindex.retry_document(Ecto.UUID.generate())
    end

    test "does not count a page an active indexing job already owns" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 1})
        page = page_with_embedding_status(document, 1, "error")
        assert {:ok, _job} = EmbeddingJob.enqueue_page(page)

        assert {:ok, 0} = Reindex.retry_document(document.id)
        assert length(all_enqueued(worker: EmbeddingJob)) == 1

        # The job that owns the revision is the one that will clear the failure.
        assert Repo.get!(Page, page.id).embedding_status == "error"
      end)
    end

    test "queues a revision whose previous indexing job was cancelled" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 1})
        page = page_with_embedding_status(document, 1, "error")

        page
        |> EmbeddingJob.page_args()
        |> EmbeddingJob.new()
        |> Repo.insert!()
        |> Ecto.Changeset.change(state: "cancelled")
        |> Repo.update!()

        # Startup recovery reads that cancellation as the revision's verdict, so
        # this call is the only way the page gets indexed again.
        assert {:ok, 1} = Reindex.retry_document(document.id)
        assert length(all_enqueued(worker: EmbeddingJob)) == 1
      end)
    end

    test "a page the database refuses costs that page, not the batch" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 2})
        _queued = page_with_embedding_status(document, 1, "error")
        rejected = page_with_embedding_status(document, 2, "error")
        reject_jobs_for(rejected.id)

        # The count is the assertion: the page before the failure was queued and
        # counted, and the call returned rather than taking the whole document
        # down with the one row the database refused. Nothing is read back
        # afterwards because the rejection aborts the test's own surrounding
        # sandbox transaction, which a real per-page transaction is not nested in.
        log =
          capture_log(fn -> assert {:ok, 1} = Reindex.retry_document(document.id) end)

        assert log =~ rejected.id
      end)
    end
  end

  defp page_with_embedding_status(document, number, status) do
    document
    |> completed_page_fixture(%{
      page_number: number,
      image_path: "documents/#{document.id}/pages/page_#{number}.png"
    })
    |> Ecto.Changeset.change(embedding_status: status)
    |> Repo.update!()
  end

  # Everything a retry of indexing alone must leave byte-identical.
  defp content_of(pages) do
    for page <- pages do
      reloaded = Repo.get!(Page, page.id)

      {reloaded.id, reloaded.translation_status, reloaded.translated_markdown,
       reloaded.original_markdown, reloaded.content_revision}
    end
  end

  # A row-level veto on one page's insert, so the batch meets a failure it cannot
  # foresee. The trigger lives inside the test's transaction and leaves with it.
  defp reject_jobs_for(page_id) do
    Repo.query!("""
    CREATE FUNCTION reindex_test_reject() RETURNS trigger AS $$
    BEGIN
      IF NEW.args->>'page_id' = '#{page_id}' THEN
        RAISE EXCEPTION 'indexing job rejected by test';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER reindex_test_reject BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION reindex_test_reject()
    """)
  end
end
