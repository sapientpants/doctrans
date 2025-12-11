defmodule Doctrans.Jobs.PdfExtractionJobTest do
  use Oban.Testing, repo: Doctrans.Repo
  use ExUnit.Case

  alias Doctrans.Jobs.PdfExtractionJob

  test "new/1 creates job with correct args" do
    document_id = Uniq.UUID.uuid7()
    file_path = "/tmp/test.pdf"

    job_changeset =
      PdfExtractionJob.new(%{
        "document_id" => document_id,
        "file_path" => file_path
      })

    assert job_changeset.changes.args["document_id"] == document_id
    assert job_changeset.changes.args["file_path"] == file_path
    assert job_changeset.changes.queue == "pdf_extraction"
    assert job_changeset.changes.worker == "Doctrans.Jobs.PdfExtractionJob"
  end
end
