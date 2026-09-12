defmodule Doctrans.Processing.DocumentOrchestratorTest do
  use Doctrans.DataCase

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.DocumentOrchestrator

  describe "DocumentOrchestrator" do
    test "starts document processing" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "queued"
        })

      assert {:ok, :processing_started} = DocumentOrchestrator.start_document_processing(document)

      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "processing"
    end

    test "completes document processing" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "processing"
        })

      assert {:ok, :completed} = DocumentOrchestrator.complete_document_processing(document)

      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "completed"
    end

    test "fails document processing" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "processing"
        })

      error_message = "Processing failed"

      assert {:ok, :failed} =
               DocumentOrchestrator.fail_document_processing(document, error_message)

      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "error"
      assert updated_doc.error_message == error_message
    end

    test "resets document for retry" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "error",
          error_message: "Previous error"
        })

      assert {:ok, :reset} = DocumentOrchestrator.reset_document_for_retry(document)

      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "queued"
      assert updated_doc.error_message == nil
    end

    test "checks if document can be processed" do
      {:ok, queued_doc} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "queued"
        })

      {:ok, processing_doc} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "processing"
        })

      {:ok, completed_doc} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "completed"
        })

      {:ok, error_doc} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "error"
        })

      assert DocumentOrchestrator.can_process_document?(queued_doc) == true
      assert DocumentOrchestrator.can_process_document?(processing_doc) == false
      assert DocumentOrchestrator.can_process_document?(completed_doc) == false
      assert DocumentOrchestrator.can_process_document?(error_doc) == false
    end

    test "gets document status" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "processing"
        })

      assert DocumentOrchestrator.get_document_status(document.id) == "processing"

      assert DocumentOrchestrator.get_document_status("019b0f62-f5ac-7227-a441-c6351a58d554") ==
               nil
    end

    test "handles non-existent document" do
      non_existent_id = Uniq.UUID.uuid7()

      assert {:error, :document_not_found} =
               DocumentOrchestrator.start_document_processing(%{id: non_existent_id})

      assert {:error, :document_not_found} =
               DocumentOrchestrator.complete_document_processing(%{id: non_existent_id})

      assert {:error, :document_not_found} =
               DocumentOrchestrator.fail_document_processing(%{id: non_existent_id}, "error")

      assert {:error, :document_not_found} =
               DocumentOrchestrator.reset_document_for_retry(%{id: non_existent_id})
    end

    test "handles already processing document" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "processing"
        })

      assert {:error, :already_processing} =
               DocumentOrchestrator.start_document_processing(document)
    end

    test "handles completed document" do
      {:ok, document} =
        Documents.create_document(%{
          title: "Test Document",
          original_filename: "test.pdf",
          target_language: "en",
          status: "completed"
        })

      assert {:error, :already_completed} =
               DocumentOrchestrator.start_document_processing(document)

      assert {:error, :cannot_reset_completed} =
               DocumentOrchestrator.reset_document_for_retry(document)
    end
  end

  describe "check_document_completion/1" do
    setup do
      document = document_fixture(%{status: "processing", total_pages: 2})
      failed = page_fixture(document, %{page_number: 1, extraction_status: "error"})

      %{document: document, failed: failed}
    end

    test "a failed page never completes the document", %{document: document, failed: failed} do
      completed_page_fixture(document, %{page_number: 2})

      assert DocumentOrchestrator.check_document_completion(document.id) == :failed

      settled = Documents.get_document!(document.id)
      assert settled.status == "error"
      assert settled.error_message == inspect({:pages_failed, [page_numbers: "1"]})
      assert Documents.failed_page_numbers(document.id) == [failed.page_number]
    end

    test "a pending retry is not a terminal failure", %{document: document, failed: failed} do
      completed_page_fixture(document, %{page_number: 2})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{"page_id" => failed.id, "generation" => failed.processing_generation}
          |> LlmProcessingJob.new()
          |> Oban.insert()

        assert DocumentOrchestrator.check_document_completion(document.id) == :retrying
      end)

      assert Documents.get_document!(document.id).status == "processing"
    end

    test "a successful retry reconciles a failed document", %{
      document: document,
      failed: failed
    } do
      completed_page_fixture(document, %{page_number: 2})
      assert DocumentOrchestrator.check_document_completion(document.id) == :failed

      {:ok, failed} =
        Documents.update_page_extraction(failed, %{
          extraction_status: "completed",
          original_markdown: "# Recovered"
        })

      {:ok, _} =
        Documents.update_page_translation(failed, %{
          translation_status: "completed",
          translated_markdown: "# Recovered translation"
        })

      assert DocumentOrchestrator.check_document_completion(document.id) == :completed

      reconciled = Documents.get_document!(document.id)
      assert reconciled.status == "completed"
      assert reconciled.error_message == nil
    end

    test "unfinished pages leave the document alone", %{document: document} do
      page_fixture(document, %{page_number: 2, extraction_status: "processing"})

      assert DocumentOrchestrator.check_document_completion(document.id) == :incomplete
      assert Documents.get_document!(document.id).status == "processing"
    end
  end
end
