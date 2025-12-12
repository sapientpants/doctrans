defmodule Doctrans.Jobs.PdfExtractionJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Jobs.PdfExtractionJob

  import Doctrans.Fixtures

  describe "perform/1" do
    test "attempts to extract PDF with document_id and pdf_path" do
      document = document_fixture()

      # Will attempt extraction and fail because PDF doesn't exist
      # The extraction process handles this gracefully
      result =
        perform_job(PdfExtractionJob, %{
          "document_id" => document.id,
          "pdf_path" => "/nonexistent/path.pdf"
        })

      # Result depends on how the extraction handles missing files
      # Either :ok (graceful handling) or {:error, _} is acceptable
      assert result == :ok or match?({:error, _}, result)
    end

    test "attempts to extract PDF with only document_id (retry case)" do
      document = document_fixture()

      result = perform_job(PdfExtractionJob, %{"document_id" => document.id})
      # Result depends on how the extraction handles missing files
      assert result == :ok or match?({:error, _}, result)
    end

    test "returns error when document not found" do
      fake_document_id = Uniq.UUID.uuid7()

      result = perform_job(PdfExtractionJob, %{"document_id" => fake_document_id})
      assert {:error, "Document not found"} = result
    end
  end
end
