defmodule Doctrans.Documents.IntakeTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Documents.Intake
  alias Doctrans.Processing.{DocumentConverterMocks, PdfExtractorMock}

  import Doctrans.Fixtures

  @moduletag :capture_log

  @pdf "%PDF-1.7\n" <> String.duplicate("x", 23)
  @zip <<0x50, 0x4B, 0x03, 0x04>> <> String.duplicate("x", 28)

  setup do
    # Keep the stored original on disk rather than extracting it.
    Mox.stub(PdfExtractorMock, :get_page_count, fn _path -> {:error, :invalid_pdf} end)
    :ok
  end

  describe "accept/2" do
    test "stores the file as original.<ext> under a generated document id" do
      path = temp_file("Report.PDF", @pdf)

      assert {:ok, document_id, "Report.PDF", stored} = Intake.accept(path, "Report.PDF")
      on_exit(fn -> File.rm_rf!(Documents.document_upload_dir(document_id)) end)

      assert {:ok, _uuid} = Ecto.UUID.cast(document_id)
      assert stored == Path.join(Documents.document_upload_dir(document_id), "original.pdf")
      assert File.read!(stored) == @pdf
    end

    test "takes a charlist path like any other Path.t()" do
      path = temp_file("Report.pdf", @pdf)

      assert {:ok, document_id, "Report.pdf", stored} =
               Intake.accept(String.to_charlist(path), "Report.pdf")

      on_exit(fn -> File.rm_rf!(Documents.document_upload_dir(document_id)) end)
      assert File.read!(stored) == @pdf
    end

    test "rejects content that does not match the claimed extension and stores nothing" do
      path = temp_file("fake.docx", @pdf)

      assert {:error, "fake.docx", :file_content_mismatch} = Intake.accept(path, "fake.docx")
      assert Documents.list_documents() == []
    end

    test "rejects a file too small to carry a header" do
      path = temp_file("stub.pdf", "%")

      assert {:error, "stub.pdf", :file_too_small} = Intake.accept(path, "stub.pdf")
    end

    test "reports a path that cannot be read" do
      assert {:error, "gone.pdf", :upload_unreadable} =
               Intake.accept("/nonexistent/upload", "gone.pdf")
    end
  end

  describe "accepted?/1" do
    test "tells a stored file from a rejection" do
      assert Intake.accepted?({:ok, Uniq.UUID.uuid7(), "a.pdf", "/a/original.pdf"})
      refute Intake.accepted?({:error, "a.pdf", :file_too_small})
    end
  end

  describe "validate_languages/2" do
    test "treats a blank source as detect automatically" do
      assert {:ok, %{source: nil, target: "en"}} = Intake.validate_languages(nil, "en")
      assert {:ok, %{source: nil, target: "en"}} = Intake.validate_languages("", "en")
      assert {:ok, %{source: nil, target: "en"}} = Intake.validate_languages("  ", "en")
    end

    test "validates a chosen source and always requires a target" do
      assert {:ok, %{source: "de", target: "en"}} = Intake.validate_languages("de", "en")
      assert {:error, _reason} = Intake.validate_languages("de", nil)
      assert {:error, _reason} = Intake.validate_languages("xx-not-a-language", "en")
    end
  end

  describe "create_and_process/2" do
    test "titles the document by its root name whatever the extension" do
      DocumentConverterMocks.missing()
      {document_id, path} = stored_upload("original.docx", @zip)

      assert {:ok, ^document_id} =
               Intake.create_and_process(
                 {:ok, document_id, "Quarterly_Report-2026.docx", path},
                 %{source: nil, target: "en"}
               )

      document = Documents.get_document!(document_id)
      assert document.title == "Quarterly Report 2026"
      assert document.original_filename == "Quarterly_Report-2026.docx"
      assert document.source_extension == ".docx"
      assert is_nil(document.source_language)
      assert document.target_language == "en"
    end

    test "strips a .pdf extension as before" do
      {document_id, path} = stored_upload("original.pdf")

      assert {:ok, ^document_id} =
               Intake.create_and_process(
                 {:ok, document_id, "annual_report.pdf", path},
                 %{source: "de", target: "en"}
               )

      assert Documents.get_document!(document_id).title == "annual report"
    end

    test "reports a failure and keeps nothing when the job cannot be queued" do
      # The extraction job refuses any extension outside the accepted list, so a
      # stored ".txt" path exercises the enqueue failure without stubbing Oban.
      {document_id, path} = stored_upload("original.txt")

      assert {:error, "notes.txt", {:unsupported_format, [format: ".txt"]}} =
               Intake.create_and_process({:ok, document_id, "notes.txt", path}, %{
                 source: "de",
                 target: "en"
               })

      assert is_nil(Documents.get_document(document_id))
      refute File.exists?(Documents.document_upload_dir(document_id))
    end

    test "reports a failure and removes the upload when the document cannot be created" do
      {document_id, path} = stored_upload("original.pdf")

      assert {:error, "_.pdf", :empty_title} =
               Intake.create_and_process({:ok, document_id, "_.pdf", path}, %{
                 source: "de",
                 target: "en"
               })

      assert is_nil(Documents.get_document(document_id))
      refute File.exists?(Documents.document_upload_dir(document_id))
    end

    test "reports a start failure and cleans up when the start path raises" do
      # A second insert of the same id raises `Ecto.ConstraintError` (the schema
      # declares no unique constraint to turn it into a changeset error), standing
      # in for the raises an unreachable database produces mid-start.
      existing = document_fixture()
      directory = Documents.document_upload_dir(existing.id)
      File.mkdir_p!(directory)
      path = Path.join(directory, "original.pdf")
      File.write!(path, @pdf)

      assert {:error, "dupe.pdf", :upload_start_failed} =
               Intake.create_and_process({:ok, existing.id, "dupe.pdf", path}, %{
                 source: "de",
                 target: "en"
               })

      # The insert never completed, so this call has no row to claim: cleanup takes
      # the directory it was handed and nothing else. Deleting whatever happens to
      # sit at that id is how a caller's own document would be destroyed by a
      # failure that had nothing to do with it.
      assert Documents.get_document!(existing.id).id == existing.id
      refute File.exists?(directory)
    end

    test "deletes only the document it created when the enqueue raises" do
      # Past the insert the row is this call's own, so cleanup may delete it.
      bystander = document_fixture()
      {document_id, path} = stored_upload("original.pdf")

      assert {:error, "notes.pdf", :upload_start_failed} =
               Intake.create_and_process(
                 {:ok, document_id, "notes.pdf", nil},
                 %{source: "de", target: "en"}
               )

      assert Documents.get_document!(bystander.id).id == bystander.id
      assert is_nil(Documents.get_document(document_id))
      refute File.exists?(Documents.document_upload_dir(document_id))
      refute File.exists?(path)
    end
  end

  # A file where `accept/2` would have put it, for driving the second step alone.
  defp stored_upload(basename, content \\ @pdf) do
    document_id = Uniq.UUID.uuid7()
    directory = Documents.document_upload_dir(document_id)
    File.mkdir_p!(directory)
    path = Path.join(directory, basename)
    File.write!(path, content)

    on_exit(fn -> File.rm_rf!(directory) end)

    {document_id, path}
  end

  # Stands in for the temp file LiveView hands over for a consumed entry.
  defp temp_file(name, content) do
    directory = Path.join(System.tmp_dir!(), "intake-#{Uniq.UUID.uuid7()}")
    File.mkdir_p!(directory)
    path = Path.join(directory, name)
    File.write!(path, content)
    on_exit(fn -> File.rm_rf!(directory) end)
    path
  end
end
