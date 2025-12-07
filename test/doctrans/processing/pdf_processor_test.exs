defmodule Doctrans.Processing.PdfProcessorTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Processing.PdfProcessor

  import Doctrans.Fixtures

  describe "extract_document/3" do
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

      assert {:error, "Document not found"} = result
    end
  end

  defp create_temp_pdf do
    path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(100_000)}.pdf")
    File.write!(path, "fake pdf content")
    path
  end
end
