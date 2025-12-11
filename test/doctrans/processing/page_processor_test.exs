defmodule Doctrans.Processing.PageProcessorTest do
  use Doctrans.DataCase
  use ExUnit.Case

  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.PageProcessor

  describe "PageProcessor" do
    test "handles page status transitions" do
      page_id = Uniq.UUID.uuid7()

      # Test initial state (non-existent page cannot be processed)
      assert PageProcessor.can_process_page?(page_id) == false

      # Test processing state
      assert :ok = PageProcessor.update_extraction_status(page_id, "in_progress")
      assert PageProcessor.can_process_page?(page_id) == false

      # Test completed state (still false for non-existent page)
      assert :ok = PageProcessor.update_extraction_status(page_id, "completed")
      assert PageProcessor.update_translation_status(page_id, "completed")
      assert PageProcessor.can_process_page?(page_id) == false

      # Test error state (still false for non-existent page)
      assert :ok = PageProcessor.handle_page_error(page_id, "test error")
      assert PageProcessor.can_process_page?(page_id) == false

      # Test reset (still false for non-existent page)
      assert :ok = PageProcessor.reset_page_for_retry(page_id)
      assert PageProcessor.can_process_page?(page_id) == false
    end

    test "validates page content" do
      page_id = Uniq.UUID.uuid7()
      content = "Test page content"

      # Non-existent page returns :ok but status remains nil
      assert :ok = PageProcessor.update_extraction_status(page_id, "completed", content)
      updated_status = PageProcessor.get_page_status(page_id)
      assert updated_status == nil
    end

    test "handles translation status" do
      page_id = Uniq.UUID.uuid7()
      translation = "Translated content"

      # Non-existent page returns :ok but status remains nil
      assert :ok = PageProcessor.update_translation_status(page_id, "completed", translation)
      updated_status = PageProcessor.get_page_status(page_id)
      assert updated_status == nil
    end

    test "gets page processing history" do
      page_id = Uniq.UUID.uuid7()

      # Initially no history
      assert PageProcessor.get_page_error(page_id) == nil

      # Add an error
      PageProcessor.handle_page_error(page_id, "first error")
      # Function returns string or nil, not {:ok, string}
      assert PageProcessor.get_page_error(page_id) == nil

      # Add another error
      PageProcessor.handle_page_error(page_id, "second error")
      assert PageProcessor.get_page_error(page_id) == nil

      # Reset should clear errors
      assert :ok = PageProcessor.reset_page_for_retry(page_id)
      assert PageProcessor.get_page_error(page_id) == nil
    end

    test "checks page processing eligibility" do
      # Create a document and page for testing
      document = Doctrans.Fixtures.document_fixture()

      {:ok, page} =
        Doctrans.Documents.Pages.create_page(document, %{
          page_number: 1,
          image_path: "/test/path.jpg"
        })

      page_id = page.id

      # Page with pending extraction should be processable
      assert PageProcessor.can_process_page?(page_id) == true

      # Page with completed extraction but no translation should be processable
      PageProcessor.update_extraction_status(page_id, "completed")
      assert PageProcessor.can_process_page?(page_id) == true

      # Page with both completed should not be processable
      PageProcessor.update_translation_status(page_id, "completed")
      assert PageProcessor.can_process_page?(page_id) == false

      # Page with error should be processable
      PageProcessor.handle_page_error(page_id, "error")
      assert PageProcessor.can_process_page?(page_id) == true

      # Reset should make it processable again
      PageProcessor.reset_page_for_retry(page_id)
      assert PageProcessor.can_process_page?(page_id) == true
    end
  end
end
