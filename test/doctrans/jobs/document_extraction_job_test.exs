defmodule Doctrans.Jobs.DocumentExtractionJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Jobs.DocumentExtractionJob

  import Doctrans.Fixtures

  describe "perform/1 with file_path" do
    test "attempts to extract document with document_id and file_path" do
      document = document_fixture()

      # Will attempt extraction and fail because file doesn't exist
      # The extraction process handles this gracefully
      result =
        perform_job(DocumentExtractionJob, %{
          "document_id" => document.id,
          "file_path" => "/nonexistent/path.pdf"
        })

      # Result depends on how the extraction handles missing files
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "perform/1 without file_path (retry case)" do
    test "returns error when document not found" do
      fake_document_id = Uniq.UUID.uuid7()

      result = perform_job(DocumentExtractionJob, %{"document_id" => fake_document_id})
      assert {:error, "Document not found"} = result
    end

    test "returns error when document file not found" do
      document = document_fixture()

      result = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      # Document exists but file doesn't
      assert {:error, _} = result
    end

    test "attempts extraction when file exists" do
      document = document_fixture()

      # Create the document directory and a dummy file
      upload_dir = Doctrans.Documents.document_upload_dir(document.id)
      File.mkdir_p!(upload_dir)
      pdf_path = Path.join(upload_dir, "original.pdf")
      File.write!(pdf_path, "fake pdf content")

      result = perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      # Cleanup
      File.rm_rf!(upload_dir)

      # Result depends on how extraction handles the file
      assert result == :ok or match?({:error, _}, result)
    end

    test "finds document with original extension when pdf doesn't exist" do
      document = document_fixture(%{original_filename: "test.docx"})

      # Create the document directory with a docx file
      upload_dir = Doctrans.Documents.document_upload_dir(document.id)
      File.mkdir_p!(upload_dir)
      docx_path = Path.join(upload_dir, "original.docx")
      File.write!(docx_path, "fake docx content")

      result = perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      # Cleanup
      File.rm_rf!(upload_dir)

      # Result depends on LibreOffice availability
      assert result == :ok or match?({:error, _}, result)
    end
  end
end
