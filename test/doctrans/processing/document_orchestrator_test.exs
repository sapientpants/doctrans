defmodule Doctrans.Processing.DocumentOrchestratorTest do
  use Doctrans.DataCase

  alias Doctrans.Documents
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
end
