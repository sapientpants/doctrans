defmodule Doctrans.Processing.RetryFailedPagesTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Chat.{Conversations, RetrievedContext}
  alias Doctrans.Documents.{Document, Lifecycle, Page, Topics}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.DocumentReprocessing

  setup do
    document = document_fixture(%{status: "error", total_pages: 3})
    succeeded = completed_page_fixture(document, %{page_number: 1})

    translation_failed =
      page_fixture(document, %{
        page_number: 2,
        extraction_status: "completed",
        translation_status: "error",
        original_markdown: "Page two source"
      })

    extraction_failed =
      page_fixture(document, %{page_number: 3, extraction_status: "error"})

    %{
      document: document,
      succeeded: succeeded,
      failed: [translation_failed, extraction_failed]
    }
  end

  describe "retry_failed_pages/2" do
    test "queues every failed page in one call", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, 2} = DocumentReprocessing.retry_failed_pages(context.document.id)

        jobs = all_enqueued(worker: LlmProcessingJob)
        assert length(jobs) == 2

        # The trap this exists for: queueing the first page makes the document
        # active, so a loop over `reprocess_page/2` would refuse the second.
        assert Enum.sort(Enum.map(jobs, & &1.args["page_id"])) ==
                 Enum.sort(Enum.map(context.failed, & &1.id))

        assert Repo.get!(Document, context.document.id).status == "processing"
      end)
    end

    test "resets the failed pages and leaves the successful one alone", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, 2} = DocumentReprocessing.retry_failed_pages(context.document.id)

        for page <- context.failed do
          retried = Repo.get!(Page, page.id)
          assert retried.extraction_status == "pending"
          assert retried.translation_status == "pending"
          assert retried.original_markdown == nil
          assert retried.processing_generation != page.processing_generation
        end

        kept = Repo.get!(Page, context.succeeded.id)
        assert kept.translation_status == "completed"
        assert kept.translated_markdown == context.succeeded.translated_markdown
        assert kept.original_markdown == context.succeeded.original_markdown
        assert kept.processing_generation == context.succeeded.processing_generation
      end)
    end

    test "records the requested models on the pages it retried", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, 2} =
                 DocumentReprocessing.retry_failed_pages(context.document.id,
                   extraction_model: "vision-v2",
                   translation_model: "text-v2"
                 )

        for page <- context.failed do
          retried = Repo.get!(Page, page.id)
          assert retried.requested_extraction_model == "vision-v2"
          assert retried.requested_translation_model == "text-v2"
        end

        jobs = all_enqueued(worker: LlmProcessingJob)

        assert Enum.sort(Enum.map(jobs, & &1.args["page_id"])) ==
                 Enum.sort(Enum.map(context.failed, & &1.id))

        for job <- jobs do
          assert job.args["extraction_model"] == "vision-v2"
          assert job.args["translation_model"] == "text-v2"
        end
      end)
    end

    test "drops the retried pages from the saved chat context", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        [retried, _other] = context.failed

        question = Conversations.start_question(context.document.id, "What do the pages say?")

        grounded =
          RetrievedContext.add(RetrievedContext.new(), [
            passage(context.succeeded),
            passage(retried)
          ])

        assert {:ok, _answer, ^grounded} =
                 Conversations.finish(question, "assistant", "Both pages", grounded)

        assert {:ok, 2} = DocumentReprocessing.retry_failed_pages(context.document.id)

        # The chunks behind the retried page are gone with its content; answering
        # from them would quote text the document no longer holds.
        assert [%{page_id: kept}] =
                 RetrievedContext.passages(Conversations.load(context.document.id).context)

        assert kept == context.succeeded.id
      end)
    end

    test "broadcasts the document and each page it reset", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        :ok = Topics.subscribe_document(context.document.id)

        assert {:ok, 2} = DocumentReprocessing.retry_failed_pages(context.document.id)

        assert_received {:document_updated, %Document{status: "processing"}}

        for page <- context.failed do
          page_id = page.id
          assert_received {:page_updated, %Page{id: ^page_id, translation_status: "pending"}}
        end
      end)
    end

    test "reports a document with nothing to retry", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 1})
        _page = completed_page_fixture(document, %{page_number: 1})

        assert {:error, :nothing_to_retry} = DocumentReprocessing.retry_failed_pages(document.id)
        assert all_enqueued(worker: LlmProcessingJob) == []
        assert Repo.get!(Document, document.id).status == "completed"
        assert Repo.get!(Page, context.succeeded.id).translation_status == "completed"
      end)
    end

    test "refuses while the run still owns the document", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, queued} =
          Lifecycle.requeue(
            context.document,
            run_attrs_fixture()
          )

        {:ok, extracting} = Lifecycle.begin_extraction(queued)

        assert {:error, :already_processing} =
                 DocumentReprocessing.retry_failed_pages(extracting.id)
      end)
    end

    test "refuses a second call while the first retry is still queued", context do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, 2} = DocumentReprocessing.retry_failed_pages(context.document.id)

        assert {:error, :already_processing} =
                 DocumentReprocessing.retry_failed_pages(context.document.id)
      end)
    end

    test "reports an unknown document" do
      assert {:error, :document_not_found} =
               DocumentReprocessing.retry_failed_pages(Ecto.UUID.generate())
    end

    test "reports an empty model override", context do
      assert {:error, :invalid_model} =
               DocumentReprocessing.retry_failed_pages(context.document.id,
                 translation_model: "  "
               )
    end
  end

  defp passage(page) do
    %{
      page_id: page.id,
      page_number: page.page_number,
      chunk_index: 0,
      content_revision: page.content_revision,
      similarity: 0.9,
      original_markdown: "Text of page #{page.page_number}",
      translated_markdown: nil
    }
  end
end
