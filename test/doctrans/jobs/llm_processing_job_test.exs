defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Documents
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{OpenAICrashStub, OpenAIMock, StartupRecovery}
  alias Oban.Engines.Basic

  import Doctrans.Fixtures

  describe "perform/1" do
    test "handles non-existent page" do
      fake_page_id = Uniq.UUID.uuid7()

      # A page that is gone will not come back, so the job is not worth retrying.
      result = perform_job(LlmProcessingJob, %{"page_id" => fake_page_id})
      assert {:cancel, :page_not_found} = result
    end

    # The processor marks the stage a crash interrupted as failed, so the page
    # has settled and the document can settle on it: `error`, named by page.
    test "a crash on the last attempt still settles the document" do
      Mox.stub_with(OpenAIMock, OpenAICrashStub)

      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      args = %{"page_id" => page.id, "generation" => page.processing_generation}

      assert_raise RuntimeError, "extraction crashed", fn ->
        perform_job(LlmProcessingJob, args, attempt: 3)
      end

      assert Documents.get_page!(page.id).extraction_status == "error"

      failed = Documents.get_document!(document.id)
      assert failed.status == "error"
      assert failed.error_message == inspect({:pages_failed, [page_numbers: "1"]})
    end

    test "a crash on the last attempt settles a document whose pages were all saved" do
      Mox.stub_with(OpenAIMock, OpenAICrashStub)

      document = document_fixture(%{status: "processing", total_pages: 2})
      page_fixture(document, %{page_number: 1, extraction_status: "error"})
      saved = completed_page_fixture(document, %{page_number: 2})
      args = %{"page_id" => saved.id, "generation" => saved.processing_generation}

      # Both stages are saved, so the processor skips them and settles the
      # document itself; the crash stub is never reached.
      assert :ok = perform_job(LlmProcessingJob, args, attempt: 3)
      assert Documents.get_document!(document.id).status == "error"
    end

    test "a crash before the last attempt leaves the document processing" do
      Mox.stub_with(OpenAIMock, OpenAICrashStub)

      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      args = %{"page_id" => page.id, "generation" => page.processing_generation}

      assert_raise RuntimeError, "extraction crashed", fn ->
        perform_job(LlmProcessingJob, args, attempt: 1)
      end

      assert Documents.get_document!(document.id).status == "processing"
    end
  end

  test "rescues an orphan and resumes its interrupted extraction" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{extraction_status: "processing"})
      job = %{"page_id" => page.id} |> LlmProcessingJob.new() |> Oban.insert!()

      job
      |> Ecto.Changeset.change(
        state: "executing",
        attempt: 1,
        attempted_at: DateTime.add(DateTime.utc_now(), -7200)
      )
      |> Repo.update!()

      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})

      assert {:ok, [%{id: rescued_id}]} =
               Basic.rescue_jobs(Oban.config(), Oban.Job, rescue_after: 3_600_000)

      assert rescued_id == job.id
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)
      saved = Documents.get_page!(page.id)
      assert saved.extraction_status == "completed"
      assert saved.translation_status == "completed"

      # The rescue reused the orphan rather than queueing a second page job; the
      # extra job is this page's indexing request, on its own queue.
      assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "llm_processing"), :count) == 1

      assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "embedding_generation"), :count) ==
               1
    end)
  end

  test "retries interrupted and errored translation without repeating extraction" do
    for status <- ["processing", "error"] do
      document = document_fixture(%{status: "processing"})

      page =
        page_fixture(document, %{
          extraction_status: "completed",
          original_markdown: "Preserved extraction",
          translation_status: status
        })

      assert :ok = perform_job(LlmProcessingJob, %{"page_id" => page.id}, attempt: 2)
      saved = Documents.get_page!(page.id)
      assert saved.original_markdown == "Preserved extraction"
      assert saved.translation_status == "completed"
    end
  end
end
