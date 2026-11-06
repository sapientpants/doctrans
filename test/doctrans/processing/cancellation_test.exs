defmodule Doctrans.Processing.CancellationTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Layout, Lifecycle, Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.{Cancellation, DocumentReprocessing, JobStates, OpenAIMock}

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

        assert JobStates.for_document(document.id).content != :idle
        assert {:ok, %Document{status: "cancelled"}} = Cancellation.cancel_document(document.id)

        assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"
        assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
        assert JobStates.for_document(document.id).content == :idle
      end)
    end

    # What a release keeps and what it moves is `PageLifecycle.release/1`'s rule,
    # tested there; this asserts only that cancelling releases.
    test "releases the mid-flight page stages" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 2})
        extracting = page_fixture(document, %{page_number: 1, extraction_status: "processing"})
        failed = page_fixture(document, %{page_number: 2, extraction_status: "error"})

        assert {:ok, _cancelled} = Cancellation.cancel_document(document.id)

        assert Repo.get!(Page, extracting.id).extraction_status == "pending"
        assert Repo.get!(Page, failed.id).extraction_status == "error"
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
        assert :cancelled = Lifecycle.settle_unguarded(document.id)
        assert Repo.get!(Document, document.id).status == "cancelled"
      end)
    end

    # Regression: a page job failing on its final attempt once wrote `error` to
    # the document directly, with no from-state check, so a straggler that
    # failed -- unlike one that succeeded -- overturned the cancellation and
    # offered the user a retry of a run they had stopped.
    test "a page job failing on its final attempt cannot overturn the user's decision" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing", total_pages: 1})
        page = page_fixture(document, %{page_number: 1})

        # Executing when the user cancels, so cancellation leaves it to finish.
        executing =
          insert_job(
            LlmProcessingJob,
            LlmProcessingJob.page_args(page, page.processing_generation, %{}),
            "executing"
          )

        assert {:ok, _cancelled} = Cancellation.cancel_document(document.id)
        :ok = Topics.subscribe_document(document.id)

        Mox.stub(OpenAIMock, :extract_markdown, fn _image_path, _opts -> {:error, :timeout} end)

        assert {:error, _} =
                 LlmProcessingJob.perform(%{executing | attempt: executing.max_attempts})

        assert Repo.get!(Document, document.id).status == "cancelled"
        refute_received {:document_updated, %Document{status: "error"}}
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
        bystander = document_fixture()

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

  describe "cancel_and_delete/1" do
    test "cancels the waiting jobs, then deletes the document and its files" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        doc = document_with_pages_fixture(%{}, 2)
        dir = Layout.document_dir(doc.id)
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)

        {:ok, job} = DocumentExtractionJob.enqueue_document(doc.id, "/tmp/original.pdf")
        assert Repo.get!(Oban.Job, job.id).state == "available"

        assert {:ok, deleted} = Cancellation.cancel_and_delete(doc)

        assert deleted.id == doc.id
        assert Repo.get!(Oban.Job, job.id).state == "cancelled"
        assert is_nil(Documents.get_document(doc.id))
        assert Documents.list_pages(doc.id) == []
        refute File.exists?(dir)
      end)
    end

    test "leaves another document's jobs alone" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        doc = document_fixture()
        other = document_fixture()
        {:ok, job} = DocumentExtractionJob.enqueue_document(other.id, "/tmp/original.pdf")

        assert {:ok, _deleted} = Cancellation.cancel_and_delete(doc)

        assert Repo.get!(Oban.Job, job.id).state == "available"
        assert Documents.get_document(other.id).id == other.id
      end)
    end

    test "succeeds when the document was already removed after lookup" do
      doc = document_fixture()
      stale = Documents.get_document(doc.id)

      assert {:ok, _} = Documents.delete_document(doc)
      assert {:ok, deleted} = Cancellation.cancel_and_delete(stale)
      assert deleted.id == doc.id
    end
  end
end
