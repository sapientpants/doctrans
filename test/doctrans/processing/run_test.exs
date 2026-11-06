defmodule Doctrans.Processing.RunTest do
  @moduledoc """
  Run at its interface: what starting, replacing and recovering a run writes,
  queues and announces, and what each refuses.
  """
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.{DocumentExtractionJob, RunCleanupJob}
  alias Doctrans.Processing.Run

  # The suite runs Oban `testing: :inline`, which executes each job at insert and
  # leaves a settled row behind. These cases assert on what was *queued*, so they
  # insert in manual mode instead.
  describe "start/2" do
    test "queues extraction, starts the run the job belongs to and announces it" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{total_pages: 2})
        :ok = Topics.subscribe_document(document.id)
        path = "/uploads/#{document.id}/original.pdf"

        assert {:ok, job} = Run.start(document.id, path)

        # A fresh upload is `queued` from the moment its job exists: `uploading`
        # means only that no run has started.
        stamped = Documents.get_document!(document.id)
        assert stamped.status == "queued"
        assert stamped.source_extension == ".pdf"
        assert stamped.processing_run_id != nil
        assert stamped.total_pages == nil

        id = document.id
        assert_received {:document_updated, %{id: ^id, status: "queued"}}

        assert job.queue == "pdf_extraction"
        assert job.state == "available"

        # The path only contributes its extension: the job reads the source back
        # from the layout, so a storage root that moves does not strand the job.
        assert job.args == %{
                 "document_id" => document.id,
                 "run_id" => stamped.processing_run_id
               }
      end)
    end

    test "refuses a document that does not exist and queues nothing" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:error, :document_not_found} =
                 Run.start(
                   Ecto.UUID.generate(),
                   "/uploads/original.pdf"
                 )

        assert all_enqueued(worker: DocumentExtractionJob) == []
      end)
    end

    test "refuses an extension that is not a supported source format, changing nothing" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture()

        assert {:error, {:unsupported_format, [format: ".txt"]}} =
                 Run.start(document.id, "/uploads/original.txt")

        # The whole start is one transaction, so the refusal rolls back the
        # extension and run it had already written.
        untouched = Documents.get_document!(document.id)
        assert untouched.status == "uploading"
        assert untouched.source_extension == nil
        assert untouched.processing_run_id == nil
        assert all_enqueued(worker: DocumentExtractionJob) == []
      end)
    end

    test "refuses a document whose run has started, under way or settled, queueing nothing" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        for status <- ~w(queued extracting processing completed error cancelled) do
          document = document_fixture(%{status: status})

          assert {:error, :already_processing} =
                   Run.start(document.id, "/uploads/original.pdf")

          untouched = Documents.get_document!(document.id)
          assert untouched.status == status
          assert untouched.source_extension == nil
        end

        assert all_enqueued(worker: DocumentExtractionJob) == []
      end)
    end
  end

  describe "replace/2" do
    test "installs a new run with the chosen models and queues extraction and cleanup" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "completed", total_pages: 2})
        :ok = Topics.subscribe_document(document.id)

        assert {:ok, {:ok, queued}} =
                 Repo.safe_transaction(fn ->
                   Run.replace(Run.lock(document.id), extraction_model: "vision-x")
                 end)

        assert queued.status == "queued"
        assert queued.processing_run_id != document.processing_run_id
        assert queued.extraction_model == "vision-x"
        assert queued.translation_model == OpenAI.translation_model()
        assert queued.total_pages == nil

        id = document.id
        assert_received {:document_updated, %{id: ^id, status: "queued"}}

        args = %{"document_id" => document.id, "run_id" => queued.processing_run_id}
        assert [%{args: ^args}] = all_enqueued(worker: DocumentExtractionJob)
        assert [%{args: ^args}] = all_enqueued(worker: RunCleanupJob)
      end)
    end

    test "refuses a document whose run is under way and queues nothing" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing"})

        assert {:ok, {:error, :already_processing}} =
                 Repo.safe_transaction(fn -> Run.replace(Run.lock(document.id)) end)

        assert Documents.get_document!(document.id).status == "processing"
        assert all_enqueued() == []
      end)
    end

    test "rolls the caller back when a job already waits for the document" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "error"})
        {:ok, :queued} = Run.recover(document)

        assert {:error, :already_processing} =
                 Repo.safe_transaction(fn -> Run.replace(Run.lock(document.id)) end)

        untouched = Documents.get_document!(document.id)
        assert untouched.status == "error"
        assert untouched.processing_run_id == document.processing_run_id
        assert [_waiting] = all_enqueued(worker: DocumentExtractionJob)
      end)
    end
  end

  describe "recover/1" do
    test "re-queues the run the document holds, marked as recovered" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "queued"})

        assert {:ok, :queued} = Run.recover(document)

        assert [job] = all_enqueued(worker: DocumentExtractionJob)
        assert job.meta == %{"recovered" => true}
        assert job.args == %{"document_id" => document.id, "run_id" => document.processing_run_id}

        assert Documents.get_document!(document.id).processing_run_id ==
                 document.processing_run_id
      end)
    end

    test "leaves a document whose job is already active to that job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "queued"})
        assert {:ok, :queued} = Run.recover(document)

        assert {:ok, :owned} = Run.recover(document)
        assert [_only] = all_enqueued(worker: DocumentExtractionJob)
      end)
    end
  end
end
