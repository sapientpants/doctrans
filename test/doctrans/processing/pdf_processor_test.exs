defmodule Doctrans.Processing.PdfProcessorTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.DocumentOrchestrator
  alias Doctrans.Processing.PdfProcessor

  import Doctrans.Fixtures

  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{ResumablePdfExtractorStub, Worker}

  describe "extract_document/3" do
    test "waits for all expected pages when processing catches up with PDF extraction" do
      original = Application.fetch_env!(:doctrans, :pdf_extractor_module)
      Application.put_env(:doctrans, :pdf_extractor_module, ResumablePdfExtractorStub)
      on_exit(fn -> Application.put_env(:doctrans, :pdf_extractor_module, original) end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing"})
        Topics.subscribe_document(document.id)
        pdf_path = create_temp_pdf()
        owner = self()

        task =
          Task.async(fn ->
            Process.put(:pause_pdf_page, {2, owner})

            Oban.Testing.with_testing_mode(:manual, fn ->
              PdfProcessor.extract_document(document.id, pdf_path, MapSet.new())
            end)
          end)

        assert_receive {:pdf_page_paused, 2}, 2_000
        assert Documents.get_document!(document.id).total_pages == 3
        assert [first_page] = Documents.list_pages(document.id)
        complete_page(first_page)

        assert DocumentOrchestrator.check_document_completion(document.id) == :incomplete
        assert Documents.get_document!(document.id).status == "processing"
        refute_received {:document_updated, %{status: "completed"}}

        send(task.pid, :resume_pdf)
        assert Task.await(task) == :ok
        assert length(Documents.list_pages(document.id)) == 3
        assert DocumentOrchestrator.check_document_completion(document.id) == :incomplete

        for page <- Documents.list_pages(document.id), page.page_number > 1 do
          complete_page(page)
        end

        assert DocumentOrchestrator.check_document_completion(document.id) == :completed
        assert Documents.get_document!(document.id).status == "completed"
        assert_received {:document_updated, %{status: "completed"}}
      end)
    end

    test "extracts pages from PDF and creates page records" do
      document = document_fixture(%{status: "extracting"})
      pdf_path = create_temp_pdf()

      result = PdfProcessor.extract_document(document.id, pdf_path, MapSet.new())

      assert result == :ok

      # Verify pages were created
      updated_doc = Documents.get_document_with_pages!(document.id)
      assert updated_doc.total_pages == 3
      assert length(updated_doc.pages) == 3

      # Verify page attributes
      for page <- updated_doc.pages do
        assert page.page_number > 0
        assert page.image_path != nil
        # Note: extraction_status may be "pending" or already "completed" if
        # LLM processing started (happens immediately after first page extraction)
        assert page.extraction_status in ["pending", "processing", "completed"]
      end

      # PDF should be deleted after extraction
      refute File.exists?(pdf_path)
    end

    test "resumes after a partial extraction failure without duplicating pages or jobs" do
      original = Application.fetch_env!(:doctrans, :pdf_extractor_module)
      Application.put_env(:doctrans, :pdf_extractor_module, ResumablePdfExtractorStub)
      on_exit(fn -> Application.put_env(:doctrans, :pdf_extractor_module, original) end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "extracting"})
        pdf_path = create_temp_pdf()

        Process.put(:fail_pdf_page, 2)

        assert {:error, {:pdf_extraction_failed, _}} =
                 PdfProcessor.extract_document(document.id, pdf_path, MapSet.new())

        assert File.exists?(pdf_path)
        failed_document = Documents.get_document!(document.id)
        assert failed_document.status == "error"
        assert is_binary(failed_document.error_message)
        assert [first_page] = Documents.list_pages(document.id)
        assert [first_job] = processing_jobs()

        assert_received {:extracted_pdf_page, 1}
        assert_received {:extracted_pdf_page, 2}
        Process.delete(:fail_pdf_page)

        Topics.subscribe_document(document.id)
        assert :ok = PdfProcessor.extract_document(document.id, pdf_path, MapSet.new())
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

        refute File.exists?(pdf_path)
      end)
    end

    test "recovers missing images and jobs while preserving completed page content" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "extracting"})
        completed = completed_page_fixture(document)
        pending = page_fixture(document, %{page_number: 2, image_path: nil})
        translating = page_fixture(document, %{page_number: 3})

        {:ok, translating} =
          Documents.update_page_extraction(translating, %{
            extraction_status: "completed",
            original_markdown: "Already extracted"
          })

        pdf_path = create_temp_pdf()
        assert :ok = PdfProcessor.extract_document(document.id, pdf_path, MapSet.new())

        pages = Documents.list_pages(document.id)
        assert Enum.map(pages, & &1.id) == [completed.id, pending.id, translating.id]

        for page <- pages do
          assert File.regular?(Path.join(Documents.uploads_dir(), page.image_path))
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
        document = document_fixture(%{status: "extracting"})
        page = page_fixture(document, %{extraction_status: "processing"})
        {:ok, job} = Worker.queue_page(page.id, page_number: 1)
        job |> Ecto.Changeset.change(state: "retryable", attempt: 1) |> Repo.update!()

        assert :ok =
                 PdfProcessor.extract_document(document.id, create_temp_pdf(), MapSet.new())

        assert Documents.get_page!(page.id).extraction_status == "processing"
        assert Repo.get!(Oban.Job, job.id).state == "retryable"
        assert length(processing_jobs()) == 3
      end)
    end

    test "skips cancelled documents" do
      document = document_fixture(%{status: "extracting"})
      pdf_path = create_temp_pdf()
      cancelled = MapSet.new([document.id])

      result = PdfProcessor.extract_document(document.id, pdf_path, cancelled)

      assert result == :cancelled

      # PDF should be deleted even for cancelled documents
      refute File.exists?(pdf_path)

      # No pages should be created
      pages = Documents.list_pages(document.id)
      assert pages == []
    end

    test "handles non-existent document" do
      fake_id = Ecto.UUID.generate()
      pdf_path = create_temp_pdf()

      result = PdfProcessor.extract_document(fake_id, pdf_path, MapSet.new())

      assert {:error, :document_not_found} = result
    end
  end

  defp complete_page(page) do
    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "completed"})
    {:ok, _page} = Documents.update_page_translation(page, %{translation_status: "completed"})
  end

  defp processing_jobs do
    worker = Oban.Worker.to_string(LlmProcessingJob)
    from(j in Oban.Job, where: j.worker == ^worker) |> Repo.all()
  end

  defp create_temp_pdf do
    path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(100_000)}.pdf")
    File.write!(path, "fake pdf content")
    path
  end
end
