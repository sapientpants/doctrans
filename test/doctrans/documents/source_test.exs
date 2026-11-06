defmodule Doctrans.Documents.SourceTest do
  @moduledoc """
  `Source` at its interface: where a document's retained original is, whether
  it is there, and how its format is recorded.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Source}

  describe "path/1" do
    test "rebuilds the path from the recorded extension" do
      document = document_fixture(%{original_filename: "renamed-later.docx"})
      {:ok, document} = Source.record_extension(document, "/uploads/x/original.pdf")

      assert Source.path(document) == Layout.original_path(document.id, ".pdf")
    end

    test "falls back to the original filename for a document from before the record existed" do
      document = document_fixture(%{original_filename: "Report.DOCX"})
      assert document.source_extension == nil

      assert Source.path(document) == Layout.original_path(document.id, ".docx")
    end

    test "is nil for a format the application does not retain" do
      document = document_fixture(%{original_filename: "notes.txt"})

      assert Source.path(document) == nil
    end
  end

  describe "available?/1" do
    test "is true only while the original is a readable regular file" do
      document = document_fixture()
      refute Source.available?(document)

      path = document_source_fixture(document)
      assert Source.available?(document)

      File.rm!(path)
      refute Source.available?(document)
    end

    test "is false for a document without a retained format" do
      refute Source.available?(document_fixture(%{original_filename: "notes.txt"}))
    end
  end

  describe "record_extension/2" do
    test "records the stored upload's extension once" do
      document = document_fixture()

      assert {:ok, recorded} = Source.record_extension(document, "/uploads/x/original.pdf")
      assert recorded.source_extension == ".pdf"

      # A second record does not overwrite the first: the stored file has not changed.
      assert {:ok, kept} = Source.record_extension(recorded, "/uploads/x/original.docx")
      assert kept.source_extension == ".pdf"
      assert Documents.get_document!(document.id).source_extension == ".pdf"
    end

    test "refuses a format that is not a supported source and writes nothing" do
      document = document_fixture()

      assert {:error, {:unsupported_format, [format: ".txt"]}} =
               Source.record_extension(document, "/uploads/x/original.txt")

      assert Documents.get_document!(document.id).source_extension == nil
    end
  end
end
