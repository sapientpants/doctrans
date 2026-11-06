defmodule Doctrans.Processing.ExtractionTest do
  @moduledoc """
  `Extraction.run/1` at its interface: a loaded document, the stored source
  where the layout keeps it, and the run the document holds.

  Documents are started the way production starts them -- through
  `DocumentExtractionJob.enqueue_document/2`, in manual Oban mode so the job
  waits -- so every case but the legacy one runs under a real run id and
  renders into that run's pages directory.
  """
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Lifecycle, PageLifecycle, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.{Extraction, ResumablePdfExtractorStub, Run}

  import Doctrans.Fixtures

  describe "run/1" do
    test "waits for all expected pages when processing catches up with PDF extraction" do
      ResumablePdfExtractorStub.install()

      Oban.Testing.with_testing_mode(:manual, fn ->
        document = queued_document()
        Topics.subscribe_document(document.id)
        owner = self()

        task =
          Task.async(fn ->
            Process.put(:pause_pdf_page, {2, owner})
            Oban.Testing.with_testing_mode(:manual, fn -> Extraction.run(document) end)
          end)

        ResumablePdfExtractorStub.await_pause(task, 2)
        assert Documents.get_document!(document.id).total_pages == 3
        assert [first_page] = Documents.list_pages(document.id)
        complete_page(first_page)

        assert Lifecycle.settle_unguarded(document.id) == :incomplete
        assert Documents.get_document!(document.id).status == "extracting"
        refute_received {:document_updated, %{status: "completed"}}

        send(task.pid, :resume_pdf)
        assert Task.await(task) == :ok
        assert length(Documents.list_pages(document.id)) == 3
        assert Documents.get_document!(document.id).status == "processing"
        assert Lifecycle.settle_unguarded(document.id) == :incomplete

        for page <- Documents.list_pages(document.id), page.page_number > 1 do
          complete_page(page)
        end

        assert Lifecycle.settle_unguarded(document.id) == :completed
        assert Documents.get_document!(document.id).status == "completed"
        assert_received {:document_updated, %{status: "completed"}}
      end)
    end

    test "renders every page under the run, records it and queues its processing" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = queued_document()
        Topics.subscribe_document(document.id)

        assert :ok = Extraction.run(document)

        # The transition into extraction is made here, not by the caller.
        assert_received {:document_updated, %{status: "extracting"}}

        updated_doc = Documents.get_document_with_pages(document.id)
        assert updated_doc.status == "processing"
        assert updated_doc.total_pages == 3
        assert Enum.map(updated_doc.pages, & &1.page_number) == [1, 2, 3]

        for page <- updated_doc.pages do
          assert File.regular?(Layout.absolute(page.image_path))
          assert Path.dirname(Layout.absolute(page.image_path)) == Run.pages_dir(document)
          assert page.extraction_status == "pending"
        end

        assert Enum.sort(Enum.map(processing_jobs(), & &1.args["page_id"])) ==
                 Enum.sort(Enum.map(updated_doc.pages, & &1.id))

        assert File.regular?(Run.source_path(document))
      end)
    end

    test "resumes after a partial extraction failure without duplicating pages or jobs" do
      ResumablePdfExtractorStub.install()

      Oban.Testing.with_testing_mode(:manual, fn ->
        document = queued_document()
        source_path = Run.source_path(document)

        Process.put(:fail_pdf_page, 2)

        assert {:error, {:pdf_extraction_failed, _}} = Extraction.run(document)

        assert File.exists?(source_path)
        failed_document = Documents.get_document!(document.id)
        assert failed_document.status == "error"
        assert is_binary(failed_document.error_message)
        assert [first_page] = Documents.list_pages(document.id)
        assert [first_job] = processing_jobs()

        assert_received {:extracted_pdf_page, 1}
        assert_received {:extracted_pdf_page, 2}
        Process.delete(:fail_pdf_page)

        Topics.subscribe_document(document.id)
        assert :ok = Extraction.run(failed_document)
        resumed_document = Documents.get_document!(document.id)
        assert resumed_document.status == "processing"
        assert resumed_document.error_message == nil
        assert_received {:document_updated, %{status: "processing", error_message: nil}}
        refute_received {:extracted_pdf_page, 1}
        assert_received {:extracted_pdf_page, 2}
        assert_received {:extracted_pdf_page, 3}
        pages = Documents.list_pages(document.id)
        assert Enum.map(pages, & &1.page_number) == [1, 2, 3]
        assert hd(pages).id == first_page.id
        jobs = processing_jobs()
        assert length(jobs) == 3
        assert Enum.any?(jobs, &(&1.id == first_job.id))

        assert Enum.sort(Enum.map(jobs, & &1.args["page_id"])) ==
                 Enum.sort(Enum.map(pages, & &1.id))

        assert File.exists?(source_path)
      end)
    end

    test "recovers missing images and jobs while preserving completed page content" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = queued_document()
        completed = completed_page_fixture(document)
        pending = page_fixture(document, %{page_number: 2, image_path: nil})
        translating = page_fixture(document, %{page_number: 3})

        {:ok, translating} =
          PageLifecycle.complete(translating, :extraction, %{markdown: "Already extracted"})

        assert :ok = Extraction.run(document)

        pages = Documents.list_pages(document.id)
        assert Enum.map(pages, & &1.id) == [completed.id, pending.id, translating.id]

        for page <- pages do
          assert File.regular?(Layout.absolute(page.image_path))
        end

        restored = Documents.get_page!(completed.id)
        assert restored.original_markdown == completed.original_markdown
        assert restored.translated_markdown == completed.translated_markdown
        assert restored.translation_status == "completed"
        assert Documents.get_page!(translating.id).original_markdown == "Already extracted"

        assert Enum.sort(Enum.map(processing_jobs(), & &1.args["page_id"])) ==
                 Enum.sort([pending.id, translating.id])
      end)
    end

    test "preserves an active processing job and interrupted page status" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = queued_document()
        page = page_fixture(document, %{extraction_status: "processing"})
        {:ok, job} = LlmProcessingJob.enqueue_page(page)
        job |> Ecto.Changeset.change(state: "retryable", attempt: 1) |> Repo.update!()

        assert :ok = Extraction.run(document)

        assert Documents.get_page!(page.id).extraction_status == "processing"
        assert Repo.get!(Oban.Job, job.id).state == "retryable"
        assert length(processing_jobs()) == 3
      end)
    end

    test "fails the document when its source is not where the layout keeps it" do
      document = document_fixture(%{status: "queued"})
      Topics.subscribe_document(document.id)

      assert {:error, :document_file_not_found} = Extraction.run(document)

      failed = Documents.get_document!(document.id)
      assert failed.status == "error"
      assert failed.error_message == ":document_file_not_found"
      assert_received {:document_updated, %{status: "error"}}
      assert Documents.list_pages(document.id) == []
    end

    test "a run the document has moved on from writes nothing and is done" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        stale = queued_document()
        Topics.subscribe_document(stale.id)

        # The run was replaced after `stale` was loaded; `Extraction` is holding
        # the previous run's document.
        stale
        |> Ecto.Changeset.change(processing_run_id: Uniq.UUID.uuid7())
        |> Repo.update!()

        assert :ok = Extraction.run(stale)

        untouched = Documents.get_document!(stale.id)
        assert untouched.status == "queued"
        assert untouched.total_pages == nil
        assert Documents.list_pages(stale.id) == []
        assert processing_jobs() == []
        refute_received {:document_updated, _}
      end)
    end

    # Rows from before runs existed have no run id; their pages live directly
    # under the document directory, and they get the same transition as any
    # other document instead of a silent skip.
    test "a legacy document without a run extracts into the legacy pages directory" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = legacy_document_fixture(%{status: "queued"})
        document_source_fixture(document)
        assert document.processing_run_id == nil
        Topics.subscribe_document(document.id)

        assert :ok = Extraction.run(document)

        assert_received {:document_updated, %{status: "extracting"}}
        updated = Documents.get_document_with_pages(document.id)
        assert updated.status == "processing"
        assert updated.total_pages == 3

        for page <- updated.pages do
          assert Path.dirname(Layout.absolute(page.image_path)) ==
                   Layout.legacy_pages_dir(document.id)
        end

        assert length(processing_jobs()) == 3
      end)
    end
  end

  # A document the way the upload path leaves it for the extraction job: the
  # source stored under the layout, the run started, the job waiting.
  defp queued_document do
    document = document_fixture()
    document_source_fixture(document)

    {:ok, _job} =
      DocumentExtractionJob.enqueue_document(document.id, Run.source_path(document))

    queued = Documents.get_document!(document.id)
    assert queued.status == "queued"
    assert is_binary(queued.processing_run_id)
    queued
  end

  defp complete_page(page) do
    {:ok, page} = PageLifecycle.complete(page, :extraction, %{markdown: ""})
    {:ok, _page} = PageLifecycle.complete(page, :translation, %{markdown: ""})
  end

  defp processing_jobs do
    worker = Oban.Worker.to_string(LlmProcessingJob)
    from(j in Oban.Job, where: j.worker == ^worker) |> Repo.all()
  end
end
