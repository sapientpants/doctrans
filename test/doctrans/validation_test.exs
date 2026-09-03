defmodule Doctrans.ValidationTest do
  use ExUnit.Case, async: true

  alias Doctrans.Validation

  defp write_file!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "validate_document_attrs/1" do
    test "returns valid attrs when all fields are present and valid" do
      attrs = %{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "en"
      }

      assert {:ok, validated_attrs} = Validation.validate_document_attrs(attrs)
      assert validated_attrs.title == "Test Document"
      assert validated_attrs.original_filename == "test.pdf"
      assert validated_attrs.target_language == "en"
    end

    test "trims title whitespace" do
      attrs = %{
        title: "  Test Document  ",
        original_filename: "test.pdf",
        target_language: "en"
      }

      assert {:ok, validated_attrs} = Validation.validate_document_attrs(attrs)
      assert validated_attrs.title == "Test Document"
    end

    test "returns error when title is empty" do
      attrs = %{
        title: "",
        original_filename: "test.pdf",
        target_language: "en"
      }

      assert {:error, "Title cannot be empty"} = Validation.validate_document_attrs(attrs)
    end

    test "returns error when title is only whitespace" do
      attrs = %{
        title: "   ",
        original_filename: "test.pdf",
        target_language: "en"
      }

      assert {:error, "Title cannot be empty"} = Validation.validate_document_attrs(attrs)
    end

    test "returns error when missing required fields" do
      attrs = %{}

      assert {:error, "Missing required fields: title, original_filename, target_language"} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when missing some required fields" do
      attrs = %{title: "Test"}

      assert {:error, "Missing required fields: original_filename, target_language"} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when title is not a string" do
      attrs = %{
        title: 123,
        original_filename: "test.pdf",
        target_language: "en"
      }

      assert {:error, "Title is required and must be a string"} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when target_language is invalid" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: "invalid"
      }

      assert {:error, reason} = Validation.validate_document_attrs(attrs)
      assert reason =~ "Unsupported language"
    end

    test "returns error when target_language is not a string" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: 123
      }

      assert {:error, "Target language is required and must be a string"} =
               Validation.validate_document_attrs(attrs)
    end

    test "sanitizes filename" do
      attrs = %{
        title: "Test",
        original_filename: "../../../etc/passwd",
        target_language: "en"
      }

      assert {:ok, validated_attrs} = Validation.validate_document_attrs(attrs)
      # Check that dangerous characters are removed
      # After sanitization, ".." becomes "_" and "/" becomes "_"
      refute String.contains?(validated_attrs.original_filename, "..")
      refute String.contains?(validated_attrs.original_filename, "/")
    end
  end

  describe "validate_search_query/1" do
    test "returns valid query for normal text" do
      query = "test search query"
      assert {:ok, "test search query"} = Validation.validate_search_query(query)
    end

    test "trims query whitespace" do
      query = "  test search query  "
      assert {:ok, "test search query"} = Validation.validate_search_query(query)
    end

    test "returns error for empty query" do
      query = ""

      assert {:error, "Query too short"} =
               Validation.validate_search_query(query)
    end

    test "returns error for only whitespace query" do
      query = "   "

      assert {:error, "Query too short"} =
               Validation.validate_search_query(query)
    end

    test "returns error for query too long" do
      long_query = String.duplicate("a", 501)
      assert {:error, reason} = Validation.validate_search_query(long_query)
      assert reason =~ "too long"
    end

    test "accepts query containing HTML/script tags without transformation" do
      query = "test <script>alert('xss')</script> query"
      assert {:ok, ^query} = Validation.validate_search_query(query)
    end

    test "returns error for non-string query" do
      query = 123
      assert {:error, "Search query must be a string"} = Validation.validate_search_query(query)
    end
  end

  describe "validate_file_content/2" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("doctrans_validation_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "accepts a valid PDF header", %{dir: dir} do
      path = write_file!(dir, "doc.pdf", "%PDF-1.4\nrest of file")
      assert :ok = Validation.validate_file_content(path, ".pdf")
    end

    test "rejects a PDF extension whose content is not a PDF", %{dir: dir} do
      path = write_file!(dir, "fake.pdf", "not a pdf at all, just text")
      assert {:error, reason} = Validation.validate_file_content(path, ".pdf")
      assert reason =~ "does not match"
    end

    test "accepts a valid DOCX (ZIP) header", %{dir: dir} do
      path = write_file!(dir, "doc.docx", <<0x50, 0x4B, 0x03, 0x04>> <> "trailing bytes")
      assert :ok = Validation.validate_file_content(path, ".docx")
    end

    test "accepts a valid ODT (ZIP) header", %{dir: dir} do
      path = write_file!(dir, "doc.odt", <<0x50, 0x4B, 0x03, 0x04>> <> "trailing bytes")
      assert :ok = Validation.validate_file_content(path, ".odt")
    end

    test "accepts a valid legacy DOC (OLE) header", %{dir: dir} do
      path = write_file!(dir, "doc.doc", <<0xD0, 0xCF, 0x11, 0xE0>> <> "trailing bytes")
      assert :ok = Validation.validate_file_content(path, ".doc")
    end

    test "accepts a valid RTF header", %{dir: dir} do
      path = write_file!(dir, "doc.rtf", "{\\rtf1\\ansi rest")
      assert :ok = Validation.validate_file_content(path, ".rtf")
    end

    test "is case-insensitive on extension", %{dir: dir} do
      path = write_file!(dir, "doc.PDF", "%PDF-1.4\ncontent")
      assert :ok = Validation.validate_file_content(path, ".PDF")
    end

    test "rejects unknown extensions", %{dir: dir} do
      path = write_file!(dir, "doc.xyz", "arbitrary content over 8 bytes")
      assert {:error, reason} = Validation.validate_file_content(path, ".xyz")
      assert reason =~ "does not match"
    end

    test "returns error for files smaller than the magic-byte window", %{dir: dir} do
      path = write_file!(dir, "tiny.pdf", "%PD")
      assert {:error, reason} = Validation.validate_file_content(path, ".pdf")
      assert reason =~ "too small"
    end

    test "returns error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.pdf")
      assert {:error, reason} = Validation.validate_file_content(path, ".pdf")
      assert reason =~ "Could not read"
    end

    test "returns error when extension is not a string", %{dir: dir} do
      path = write_file!(dir, "doc.pdf", "%PDF-1.4\nrest")
      assert {:error, reason} = Validation.validate_file_content(path, nil)
      assert reason =~ "must be strings"
    end

    test "returns error when file path is not a string" do
      assert {:error, reason} = Validation.validate_file_content(nil, ".pdf")
      assert reason =~ "must be strings"
    end
  end

  describe "validate_language/1" do
    test "returns valid for supported languages" do
      supported_languages = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "no", "da", "pl"]

      Enum.each(supported_languages, fn lang ->
        assert {:ok, ^lang} = Validation.validate_language(lang)
      end)
    end

    test "returns error for unsupported language" do
      assert {:error, reason} = Validation.validate_language("invalid")
      assert reason =~ "Unsupported language"
    end

    test "returns error for non-string language" do
      assert {:error, reason} = Validation.validate_language(123)
      assert reason =~ "must be a string"
    end

    test "returns error for empty language" do
      assert {:error, reason} = Validation.validate_language("")
      assert reason =~ "Unsupported language"
    end

    test "normalizes language case" do
      assert {:ok, "en"} = Validation.validate_language("EN")
      assert {:ok, "es"} = Validation.validate_language("ES")
    end
  end

  describe "sanitize_filename_string/1" do
    test "removes path traversal characters" do
      filename = "../../../etc/passwd"
      sanitized = Validation.sanitize_filename_string(filename)
      refute sanitized =~ ".."
      refute sanitized =~ "/"
    end

    test "removes null bytes" do
      filename = "test\0file.pdf"
      sanitized = Validation.sanitize_filename_string(filename)
      refute sanitized =~ "\0"
      assert sanitized == "testfile.pdf"
    end

    test "preserves valid characters" do
      filename = "test-file_123.pdf"
      sanitized = Validation.sanitize_filename_string(filename)
      assert sanitized == "test-file_123.pdf"
    end

    test "handles empty filename" do
      assert "" == Validation.sanitize_filename_string("")
    end

    test "handles nil filename" do
      assert "" == Validation.sanitize_filename_string(nil)
    end
  end
end
