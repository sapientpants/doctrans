defmodule Doctrans.Processing.CancellationTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.{Cancellation, DocumentOrchestrator, DocumentReprocessing}

  @moduletag :postgres

  describe "cancel_document/1" do
    test "cancels the queued jobs, leaves an executing one, and settles the document" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 2})
        page = page_fixture(document, %{page_number: 1})
        :ok = Topics.subscribe_document(document.id)

        queued =
          for state <- ~w(available scheduled retryable) do
            insert_job(LlmProcessingJob, %{"page_id" => page.id}, state)
          end

        extraction =
          insert_job(DocumentExtractionJob, %{"document_id" => document.id}, "available")

        # Oban runs an executing job to completion; cancellation stops what has
        # not started, and the document status is what contains the rest.
        executing =
          insert_job(DocumentExtractionJob, %{"document_id" => document.id}, "executing")

        assert {:ok, cancelled} = Cancellation.cancel_document(document.id)
        assert cancelled.status == "cancelled"
        assert Repo.get!(Document, document.id).status == "cancelled"

        for job <- [extraction | queued] do
          assert Repo.get!(Oban.Job, job.id).state == "cancelled"
        end

        assert Repo.get!(Oban.Job, executing.id).state == "executing"
        assert_received {:document_updated, %Document{status: "cancelled"}}
      end)
    end

    test "clears the diagnostic a failing page recorded" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 1})
        {:ok, _} = Documents.update_document_status(document, "processing", :page_failed)
        assert Repo.get!(Document, document.id).error_message

        assert {:ok, cancelled} = Cancellation.cancel_document(document)
        assert cancelled.error_message == nil
      end)
    end

    test "returns the mid-flight page stages to pending without touching content" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 3})

        extracting = page_fixture(document, %{page_number: 1, extraction_status: "processing"})

        translating =
          page_fixture(document, %{
            page_number: 2,
            extraction_status: "completed",
            translation_status: "processing",
            original_markdown: "Extracted text"
          })

        done = completed_page_fixture(document, %{page_number: 3})

        assert {:ok, _cancelled} = Cancellation.cancel_document(document.id)

        assert Repo.get!(Page, extracting.id).extraction_status == "pending"

        settled = Repo.get!(Page, translating.id)
        assert settled.translation_status == "pending"
        # The finished stage keeps its verdict and its output.
        assert settled.extraction_status == "completed"
        assert settled.original_markdown == "Extracted text"

        finished = Repo.get!(Page, done.id)
        assert finished.translation_status == "completed"
        assert finished.translated_markdown == done.translated_markdown
      end)
    end

    test "refuses a document that has already settled" do
      document = document_fixture(%{status: "completed", total_pages: 1})

      assert {:error, :not_cancellable} = Cancellation.cancel_document(document.id)
      assert Repo.get!(Document, document.id).status == "completed"
    end

    test "reports an unknown document" do
      assert {:error, :document_not_found} = Cancellation.cancel_document(Ecto.UUID.generate())
    end
  end

  describe "after cancellation" do
    test "a straggler job cannot overturn the user's decision" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 1})
        _page = completed_page_fixture(document, %{page_number: 1})

        assert {:ok, _cancelled} = Cancellation.cancel_document(document.id)

        # The job that was executing when the user cancelled finishes and asks
        # for the document to be settled; every page reads as a success.
        assert :cancelled = DocumentOrchestrator.check_document_completion(document.id)
        assert Repo.get!(Document, document.id).status == "cancelled"
      end)
    end

    test "the document can be reprocessed without being deleted" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 1})
        _source = document_source_fixture(document)
        _page = page_fixture(document, %{page_number: 1, extraction_status: "processing"})

        assert {:ok, _cancelled} = Cancellation.cancel_document(document.id)
        assert {:ok, run} = DocumentReprocessing.reprocess_document(document.id)
        assert run.status == "queued"
        assert [_job] = all_enqueued(worker: DocumentExtractionJob)
      end)
    end
  end

  defp insert_job(worker, args, state) do
    args
    |> worker.new()
    |> Repo.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
  end
end
