defmodule Doctrans.Processing.WorkerTest do
  # Everything here but the last describe runs in the test process: the module's
  # public functions talk to Oban and the repo directly and never reach the
  # GenServer. `recover_now/1` does, so that block starts an unnamed instance of
  # its own and hands it the sandbox connection, the way
  # `worker_callbacks_test.exs` does.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Jobs.{EmbeddingJob, HealthCheckJob}
  alias Doctrans.Processing.Worker
  alias Ecto.Adapters.SQL.Sandbox

  import Doctrans.Fixtures

  # The suite runs Oban `testing: :inline`, which executes each job at insert and
  # leaves a settled row behind. These cases assert on what was *queued* -- args,
  # priority, queue, cancellation -- so they insert in manual mode instead.
  defp queued(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  describe "status/0" do
    test "counts the jobs waiting in each queue" do
      queued(fn ->
        document = document_fixture()
        page = page_fixture(document, %{page_number: 1})

        {:ok, _extraction} = Worker.process_document(document.id, "/uploads/original.pdf")
        {:ok, _processing} = Worker.queue_page(page.id, page_number: 1)
        {:ok, _indexing} = EmbeddingJob.enqueue_page(page)
        {:ok, _health} = Oban.insert(HealthCheckJob.new(%{}))

        assert Worker.status() == %{
                 pdf_extraction: 1,
                 llm_processing: 1,
                 embedding_generation: 1,
                 health_check: 1
               }
      end)
    end

    test "reports zero for every queue when nothing has been queued" do
      assert Worker.status() == %{
               pdf_extraction: 0,
               llm_processing: 0,
               embedding_generation: 0,
               health_check: 0
             }
    end
  end

  describe "process_document/2" do
    test "queues extraction and stamps the run the job belongs to" do
      queued(fn ->
        document = document_fixture(%{status: "queued"})
        path = "/uploads/#{document.id}/original.pdf"

        assert {:ok, job} = Worker.process_document(document.id, path)

        stamped = Documents.get_document!(document.id)
        assert stamped.source_extension == ".pdf"
        assert stamped.processing_run_id != nil

        assert job.queue == "pdf_extraction"
        assert job.state == "available"

        assert job.args == %{
                 "document_id" => document.id,
                 "run_id" => stamped.processing_run_id,
                 "file_path" => path
               }
      end)
    end

    test "refuses a document that does not exist and queues nothing" do
      queued(fn ->
        assert {:error, :document_not_found} =
                 Worker.process_document(Ecto.UUID.generate(), "/uploads/original.pdf")

        assert Worker.status().pdf_extraction == 0
      end)
    end

    test "refuses an extension that is not a supported source format, changing nothing" do
      queued(fn ->
        document = document_fixture()

        assert {:error, {:unsupported_format, [format: ".txt"]}} =
                 Worker.process_document(document.id, "/uploads/original.txt")

        # The whole enqueue is one transaction, so the refusal rolls back the
        # extension and run it had already written.
        untouched = Documents.get_document!(document.id)
        assert untouched.source_extension == nil
        assert untouched.processing_run_id == nil
        assert Worker.status().pdf_extraction == 0
      end)
    end
  end

  describe "queue_page/2" do
    test "queues the page at the ordinary priority with its generation and model" do
      queued(fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document, %{page_number: 4})

        assert {:ok, job} = Worker.queue_page(page.id, page_number: 4, extraction_model: "vision")

        assert job.queue == "llm_processing"
        assert job.priority == 2

        assert job.args == %{
                 "page_id" => page.id,
                 "page_number" => 4,
                 "generation" => page.processing_generation,
                 "extraction_model" => "vision"
               }
      end)
    end

    test "defaults the page number when the caller does not supply one" do
      queued(fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document, %{page_number: 7})

        assert {:ok, job} = Worker.queue_page(page.id)
        assert job.args["page_number"] == 0
      end)
    end

    test "a page id with no row behind it queues with no generation to guard" do
      queued(fn ->
        page_id = Ecto.UUID.generate()

        assert {:ok, job} = Worker.queue_page(page_id)

        # `generation` is the guard a replayed job checks against the page it
        # was queued for; there is no page here, so there is none to read.
        assert job.args == %{"page_id" => page_id, "page_number" => 0, "generation" => nil}
      end)
    end

    test "queueing a page twice returns the job already queued for it" do
      queued(fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document)

        {:ok, first} = Worker.queue_page(page.id, page_number: 1)
        {:ok, second} = Worker.queue_page(page.id, page_number: 1)

        # Uniqueness on :page_id is what keeps one page from being processed twice.
        assert second.id == first.id
        assert second.conflict?
        assert Worker.status().llm_processing == 1
      end)
    end
  end

  describe "queue_page_reprocess/2" do
    test "queues ahead of ordinary processing and carries both model overrides" do
      queued(fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document)

        assert {:ok, job} =
                 Worker.queue_page_reprocess(page.id,
                   extraction_model: "vision",
                   translation_model: "text"
                 )

        assert job.queue == "llm_processing"
        # Lower is sooner: a reprocess a person is waiting on outranks the
        # priority 2 of the queueing above.
        assert job.priority == 1

        assert job.args == %{
                 "page_id" => page.id,
                 "generation" => page.processing_generation,
                 "extraction_model" => "vision",
                 "translation_model" => "text"
               }
      end)
    end

    test "omits the overrides the caller did not request" do
      queued(fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document)

        assert {:ok, job} = Worker.queue_page_reprocess(page.id)

        assert job.args == %{
                 "page_id" => page.id,
                 "generation" => page.processing_generation
               }
      end)
    end
  end

  describe "cancel_document/1" do
    test "cancels the document's extraction and its pages' processing, and nothing else" do
      queued(fn ->
        document = document_fixture(%{status: "extracting"})
        page = page_fixture(document)
        bystander = document_fixture(%{status: "extracting"})
        bystander_page = page_fixture(bystander)

        {:ok, extraction} = Worker.process_document(document.id, "/uploads/original.pdf")
        {:ok, processing} = Worker.queue_page(page.id, page_number: 1)
        {:ok, other_extraction} = Worker.process_document(bystander.id, "/uploads/original.pdf")
        {:ok, other_processing} = Worker.queue_page(bystander_page.id, page_number: 1)

        assert :ok = Worker.cancel_document(document.id)

        assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"
        assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
        assert Repo.get!(Oban.Job, other_extraction.id).state == "available"
        assert Repo.get!(Oban.Job, other_processing.id).state == "available"
      end)
    end

    test "cancels the extraction of a document that has no pages yet" do
      queued(fn ->
        document = document_fixture(%{status: "queued"})
        {:ok, extraction} = Worker.process_document(document.id, "/uploads/original.pdf")

        assert :ok = Worker.cancel_document(document.id)
        assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"
      end)
    end

    test "cancelling a document that does not exist leaves every other job alone" do
      queued(fn ->
        bystander = document_fixture(%{status: "extracting"})
        {:ok, untouched} = Worker.process_document(bystander.id, "/uploads/original.pdf")

        assert :ok = Worker.cancel_document(Ecto.UUID.generate())
        assert Repo.get!(Oban.Job, untouched.id).state == "available"
      end)
    end
  end

  describe "recover_now/1" do
    setup do
      # The application's worker owns the registered name, and `config/test.exs`
      # leaves its boot-time pass off; this instance is driven on demand and
      # stopped with the test.
      worker =
        start_supervised!(
          %{id: :worker_under_test, start: {GenServer, :start_link, [Worker, []]}},
          restart: :temporary
        )

      Sandbox.allow(Repo, self(), worker)

      %{worker: worker}
    end

    test "runs every phase and returns only once the pass is done", %{worker: worker} do
      queued(fn ->
        # A crash between the last page write and the document update leaves
        # this behind: the page settled, the document still "processing". Only
        # the last phase of the pass resolves it, so a reply that arrives before
        # the pass reached that phase would leave the document as it was.
        document = document_fixture(%{status: "processing", total_pages: 1})

        document
        |> completed_page_fixture()
        |> Ecto.Changeset.change(embedding_status: "completed")
        |> Repo.update!()

        assert Worker.recover_now(worker) == :ok

        assert Documents.get_document!(document.id).status == "completed"

        # The phases ahead of it had nothing to resume, and the last one queues
        # nothing by design.
        assert Worker.status() == %{
                 pdf_extraction: 0,
                 llm_processing: 0,
                 embedding_generation: 0,
                 health_check: 0
               }
      end)
    end
  end
end
