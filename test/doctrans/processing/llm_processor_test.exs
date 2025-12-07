defmodule Doctrans.Processing.LlmProcessorTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.LlmProcessor

  import Doctrans.Fixtures

  describe "process_document/2" do
    test "processes all pages successfully" do
      document = document_with_pages_fixture(%{status: "processing"}, 2)

      # Set up pages with image paths and pending status
      pages = Documents.list_pages(document.id)

      for page <- pages do
        # Create the image file path for the mock to find
        upload_dir = Documents.uploads_dir()
        full_path = Path.join(upload_dir, page.image_path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, "fake image")
      end

      result = LlmProcessor.process_document(document.id, MapSet.new())

      assert result == :ok

      # Verify document is completed
      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "completed"

      # Verify pages are processed
      for page <- Documents.list_pages(document.id) do
        assert page.extraction_status == "completed"
        assert page.translation_status == "completed"
        assert page.original_markdown != nil
        assert page.translated_markdown != nil
      end
    end

    test "skips cancelled documents" do
      document = document_with_pages_fixture(%{status: "processing"}, 1)
      cancelled = MapSet.new([document.id])

      result = LlmProcessor.process_document(document.id, cancelled)

      assert result == :ok

      # Document status should not change
      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "processing"
    end

    test "skips already completed pages" do
      document = document_fixture(%{status: "processing"})
      _page = completed_page_fixture(document, %{page_number: 1})

      result = LlmProcessor.process_document(document.id, MapSet.new())

      assert result == :ok

      # Document should be completed
      updated_doc = Documents.get_document!(document.id)
      assert updated_doc.status == "completed"
    end

    test "handles cancelled during processing" do
      document = document_with_pages_fixture(%{status: "processing"}, 3)
      cancelled = MapSet.new([document.id])

      # Mark first page as extraction completed so we skip to translation check
      pages = Documents.list_pages(document.id)
      page = List.first(pages)

      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: "# Test"
      })

      result = LlmProcessor.process_document(document.id, cancelled)

      assert result == :ok
    end

    test "handles non-existent document" do
      fake_id = Ecto.UUID.generate()

      # Should raise because document doesn't exist
      assert_raise Ecto.NoResultsError, fn ->
        LlmProcessor.process_document(fake_id, MapSet.new())
      end
    end
  end
end
