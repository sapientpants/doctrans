defmodule Doctrans.Processing.CancellationTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.{Cancellation, Completion, DocumentReprocessing, Run}

  @moduletag :postgres

  describe "cancel_document/1" do
    test "cancels the queued jobs, leaves an executing one, and settles the document" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 2})
        page = page_fixture(document, %{page_number: 1})
        :ok = Topics.subscribe_document(document.id)

        queued =
          for state <- ~w(available scheduled retryable suspended) do
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

    # Regression: the cancel path once listed three cancellable states while every
    # other predicate counted `suspended` as active, so a suspended job blocked
    # reprocessing yet survived cancellation.
    test "cancels a suspended job of either shape" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 1})
        page = page_fixture(document, %{page_number: 1})

        extraction =
          insert_job(DocumentExtractionJob, %{"document_id" => document.id}, "suspended")

        processing = insert_job(LlmProcessingJob, %{"page_id" => page.id}, "suspended")

        assert Run.active?(document.id)
        assert {:ok, %Document{status: "cancelled"}} = Cancellation.cancel_document(document.id)

        assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"
        assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
        refute Run.active?(document.id)
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
        assert :cancelled = Completion.check_document_completion(document.id)
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

  describe "cancel_jobs/1" do
    test "cancels all pending states while preserving running, terminal, and unrelated jobs" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture()
        pages = for number <- 1..2, do: page_fixture(document, %{page_number: number})
        other_document = document_fixture()
        other_page = page_fixture(other_document)

        states =
          ~w(available scheduled retryable suspended executing completed discarded cancelled)

        for state <- states do
          # Literal keys also cover jobs persisted before the shared key definitions.
          extraction = insert_job(DocumentExtractionJob, %{"document_id" => document.id}, state)

          processing =
            Enum.map(pages, fn page ->
              insert_job(LlmProcessingJob, %{"page_id" => page.id}, state)
            end)

          other = insert_job(LlmProcessingJob, %{"page_id" => other_page.id}, state)

          unrelated =
            insert_job(DocumentExtractionJob, %{"document_id" => other_document.id}, state)

          assert :ok = Cancellation.cancel_jobs(document.id)

          expected =
            if state in ~w(available scheduled retryable suspended), do: "cancelled", else: state

          for job <- [extraction | processing] do
            assert Repo.get!(Oban.Job, job.id).state == expected
          end

          assert Repo.get!(Oban.Job, other.id).state == state
          assert Repo.get!(Oban.Job, unrelated.id).state == state
        end
      end)
    end

    test "cancels extraction without pages and page jobs queued at either priority" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture()

        {:ok, extraction} =
          DocumentExtractionJob.enqueue_document(document.id, "/tmp/document.pdf")

        assert :ok = Cancellation.cancel_jobs(document.id)
        assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"

        page = page_fixture(document)
        {:ok, processing} = LlmProcessingJob.enqueue_page(page)

        {:ok, reprocessing} =
          page
          |> LlmProcessingJob.page_args(page.processing_generation, %{"extraction_model" => "x"})
          |> LlmProcessingJob.new(priority: 1)
          |> Oban.insert()

        assert :ok = Cancellation.cancel_jobs(document.id)
        assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
        assert Repo.get!(Oban.Job, reprocessing.id).state == "cancelled"
      end)
    end

    test "cancelling a document that does not exist leaves every other job alone" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        bystander = document_fixture(%{status: "extracting"})

        {:ok, untouched} =
          DocumentExtractionJob.enqueue_document(bystander.id, "/uploads/original.pdf")

        assert :ok = Cancellation.cancel_jobs(Ecto.UUID.generate())
        assert Repo.get!(Oban.Job, untouched.id).state == "available"
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
