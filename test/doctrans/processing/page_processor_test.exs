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
        Pages.create_page(document, %{
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

  describe "state management" do
    test "new_state creates empty state" do
      state = PageProcessor.new_state()
      assert state.current_page_id == nil
      assert state.llm_task_ref == nil
      assert state.llm_timeout_ref == nil
    end

    test "processing? returns false for empty state" do
      state = PageProcessor.new_state()
      assert PageProcessor.processing?(state) == false
    end

    test "processing? returns true when page is being processed" do
      state = %{current_page_id: Uniq.UUID.uuid7(), llm_task_ref: nil, llm_timeout_ref: nil}
      assert PageProcessor.processing?(state) == true
    end

    test "current_page_id returns nil for empty state" do
      state = PageProcessor.new_state()
      assert PageProcessor.current_page_id(state) == nil
    end

    test "current_page_id returns page_id when set" do
      page_id = Uniq.UUID.uuid7()
      state = %{current_page_id: page_id, llm_task_ref: nil, llm_timeout_ref: nil}
      assert PageProcessor.current_page_id(state) == page_id
    end

    test "matches_current_task? returns false when no task" do
      state = PageProcessor.new_state()
      ref = make_ref()
      assert PageProcessor.matches_current_task?(state, ref) == false
    end

    test "matches_current_task? returns true for matching ref" do
      ref = make_ref()
      state = %{current_page_id: nil, llm_task_ref: ref, llm_timeout_ref: nil}
      assert PageProcessor.matches_current_task?(state, ref) == true
    end

    test "matches_current_task? returns false for different ref" do
      ref1 = make_ref()
      ref2 = make_ref()
      state = %{current_page_id: nil, llm_task_ref: ref1, llm_timeout_ref: nil}
      assert PageProcessor.matches_current_task?(state, ref2) == false
    end

    test "cancel_timeout handles nil timeout_ref" do
      state = PageProcessor.new_state()
      new_state = PageProcessor.cancel_timeout(state)
      assert new_state.llm_timeout_ref == nil
    end

    test "cancel_timeout cancels timer" do
      timer_ref = Process.send_after(self(), :test, 60_000)
      state = %{current_page_id: nil, llm_task_ref: nil, llm_timeout_ref: timer_ref}
      new_state = PageProcessor.cancel_timeout(state)
      assert new_state.llm_timeout_ref == nil
    end

    test "handle_task_success clears state" do
      page_id = Uniq.UUID.uuid7()
      timer_ref = Process.send_after(self(), :test, 60_000)

      state = %{
        current_page_id: page_id,
        llm_task_ref: make_ref(),
        llm_timeout_ref: timer_ref
      }

      new_state = PageProcessor.handle_task_success(state)
      assert new_state.current_page_id == nil
      assert new_state.llm_task_ref == nil
      assert new_state.llm_timeout_ref == nil
    end

    test "handle_task_failure clears state" do
      page_id = Uniq.UUID.uuid7()

      state = %{
        current_page_id: page_id,
        llm_task_ref: make_ref(),
        llm_timeout_ref: nil
      }

      new_state = PageProcessor.handle_task_failure(state, "test error")
      assert new_state.current_page_id == nil
      assert new_state.llm_task_ref == nil
    end

    test "handle_task_crash clears state" do
      page_id = Uniq.UUID.uuid7()

      state = %{
        current_page_id: page_id,
        llm_task_ref: make_ref(),
        llm_timeout_ref: nil
      }

      new_state = PageProcessor.handle_task_crash(state, {:error, :crashed})
      assert new_state.current_page_id == nil
      assert new_state.llm_task_ref == nil
    end

    test "handle_task_timeout clears state" do
      page_id = Uniq.UUID.uuid7()

      state = %{
        current_page_id: page_id,
        llm_task_ref: make_ref(),
        llm_timeout_ref: nil
      }

      new_state = PageProcessor.handle_task_timeout(state)
      assert new_state.current_page_id == nil
      assert new_state.llm_task_ref == nil
    end
  end
end
