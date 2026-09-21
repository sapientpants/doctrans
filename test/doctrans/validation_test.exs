defmodule Doctrans.ValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Doctrans.Validation

  # The directory a sanitized filename would be joined onto. Absolute and already
  # expanded, so `Path.expand/1` on a join with it moves only for a `..` component.
  @upload_dir "/var/doctrans/uploads"

  # What a hostile client puts in a multipart filename. Ordered cheapest-first so a
  # shrunk counterexample names the smallest fragment that still breaks the
  # invariant: traversal shapes, both separators, NUL and other C0 controls, the
  # Windows-reserved set, absolute and drive-letter paths, 2-, 3- and 4-byte UTF-8,
  # a ZWJ grapheme cluster, and byte sequences that are not UTF-8 at all.
  @fragments [
    "a",
    ".",
    "..",
    "/",
    "\\",
    <<0>>,
    "../",
    "..\\",
    "....//",
    "./",
    "...",
    "//",
    "/etc/passwd",
    "C:\\Windows\\system32",
    "file",
    ".pdf",
    "-",
    "_",
    " ",
    "\t",
    "\n",
    <<1>>,
    <<0x1F>>,
    "<",
    ">",
    ":",
    "\"",
    "?",
    "*",
    "|",
    "Übermäßig",
    "文書",
    "वाक्य",
    "👨‍👩‍👧‍👦",
    <<0xFF>>,
    <<0xC3>>,
    <<0xED, 0xA0, 0x80>>,
    <<0xF0, 0x9F>>
  ]

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
        target_language: "en",
        source_language: "de"
      }

      assert {:ok, validated_attrs} = Validation.validate_document_attrs(attrs)
      assert validated_attrs.title == "Test Document"
      assert validated_attrs.original_filename == "test.pdf"
      assert validated_attrs.target_language == "en"
      assert validated_attrs.source_language == "de"
    end

    test "trims title whitespace" do
      attrs = %{
        title: "  Test Document  ",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de"
      }

      assert {:ok, validated_attrs} = Validation.validate_document_attrs(attrs)
      assert validated_attrs.title == "Test Document"
    end

    test "returns error when title is empty" do
      attrs = %{
        title: "",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de"
      }

      assert {:error, :empty_title} = Validation.validate_document_attrs(attrs)
    end

    test "returns error when title is only whitespace" do
      attrs = %{
        title: "   ",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de"
      }

      assert {:error, :empty_title} = Validation.validate_document_attrs(attrs)
    end

    test "returns error when missing required fields" do
      attrs = %{}

      assert {:error,
              {:missing_required_fields,
               [fields: "title, original_filename, target_language, source_language"]}} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when missing some required fields" do
      attrs = %{title: "Test"}

      assert {:error,
              {:missing_required_fields,
               [fields: "original_filename, target_language, source_language"]}} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when title is not a string" do
      attrs = %{
        title: 123,
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de"
      }

      assert {:error, :invalid_title} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when target_language is invalid" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: "invalid",
        source_language: "de"
      }

      assert {:error, reason} = Validation.validate_document_attrs(attrs)
      assert {:unsupported_language, [language: _]} = reason
    end

    test "returns error when target_language is not a string" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: 123,
        source_language: "de"
      }

      assert {:error, :invalid_target_language} =
               Validation.validate_document_attrs(attrs)
    end

    test "returns error when source_language is invalid" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "xx"
      }

      assert {:error, reason} = Validation.validate_document_attrs(attrs)
      assert {:unsupported_language, [language: "xx"]} = reason
    end

    test "returns error when source_language is not a string" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: 123
      }

      assert {:error, :invalid_source_language} =
               Validation.validate_document_attrs(attrs)
    end

    test "sanitizes filename" do
      attrs = %{
        title: "Test",
        original_filename: "../../../etc/passwd",
        target_language: "en",
        source_language: "de"
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

      assert {:error, :query_too_short} =
               Validation.validate_search_query(query)
    end

    test "returns error for only whitespace query" do
      query = "   "

      assert {:error, :query_too_short} =
               Validation.validate_search_query(query)
    end

    test "returns error for query too long" do
      long_query = String.duplicate("a", 501)
      assert {:error, reason} = Validation.validate_search_query(long_query)
      assert reason == {:query_too_long, [max: 500]}
    end

    test "accepts query containing HTML/script tags without transformation" do
      query = "test <script>alert('xss')</script> query"
      assert {:ok, ^query} = Validation.validate_search_query(query)
    end

    test "returns error for non-string query" do
      query = 123
      assert {:error, :invalid_query} = Validation.validate_search_query(query)
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
      assert reason == :file_content_mismatch
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
      assert reason == :file_content_mismatch
    end

    test "returns error for files smaller than the magic-byte window", %{dir: dir} do
      path = write_file!(dir, "tiny.pdf", "%PD")
      assert {:error, reason} = Validation.validate_file_content(path, ".pdf")
      assert reason == :file_too_small
    end

    test "returns error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "missing.pdf")
      assert {:error, reason} = Validation.validate_file_content(path, ".pdf")
      assert reason == :file_unreadable
    end

    test "returns error when extension is not a string", %{dir: dir} do
      path = write_file!(dir, "doc.pdf", "%PDF-1.4\nrest")
      assert {:error, reason} = Validation.validate_file_content(path, nil)
      assert reason == :invalid_file_arguments
    end

    test "returns error when file path is not a string" do
      assert {:error, reason} = Validation.validate_file_content(nil, ".pdf")
      assert reason == :invalid_file_arguments
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
      assert {:unsupported_language, [language: _]} = reason
    end

    test "returns error for non-string language" do
      assert {:error, reason} = Validation.validate_language(123)
      assert reason == :invalid_language
    end

    test "returns error for empty language" do
      assert {:error, reason} = Validation.validate_language("")
      assert {:unsupported_language, [language: _]} = reason
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

    # Shrunk counterexamples from the property below, kept as examples so the two
    # clauses that matter stay pinned by a named input even if the generator is
    # ever changed (PLAN.md Q05).
    test "collapses a traversal prefix to underscores" do
      assert Validation.sanitize_filename_string("../") == "__"
      assert Validation.sanitize_filename_string("..\\") == "__"
    end

    test "an absolute path collapses to one component" do
      assert Validation.sanitize_filename_string("/etc/passwd") == "_etc_passwd"
      assert Validation.sanitize_filename_string("C:\\Windows\\system32") == "C__Windows_system32"
    end

    # Regression, found by the property below (PLAN.md Q05): the NUL strip used to
    # run after the ".." replacement and closed up a ".." it never saw, so ".\0."
    # sanitized to ".." -- a filename resolving to the parent directory.
    test "a NUL between two dots cannot rebuild `..`" do
      assert Validation.sanitize_filename_string(".\0.") == "_"
      assert Validation.sanitize_filename_string("a.\0.b") == "a_b"
    end
  end

  describe "sanitize_filename_string/1 (property)" do
    # 50 runs rather than the default 100: a draw is a handful of hostile
    # fragments concatenated at most six deep -- 7 bytes at the median and 76 at
    # the largest over a thousand draws -- and 50 draws already land a traversal
    # in 24% of them, a separator in 44% and invalid UTF-8 in 36%. The bound is
    # what keeps pull-request latency predictable (PLAN.md Q05). The examples
    # above state this by example and none of them states the containment clause,
    # which is the one that matters.
    property "the result is one component that cannot escape the directory it is joined onto" do
      check all(filename <- filename(), max_runs: 50) do
        result = Validation.sanitize_filename_string(filename)

        assert Path.basename(result) == result,
               "#{inspect(filename)} sanitized to a multi-component path"

        refute String.contains?(result, ["/", "\\", <<0>>]),
               "#{inspect(filename)} sanitized to #{inspect(result)}, which still holds a separator"

        refute String.contains?(result, ".."),
               "#{inspect(filename)} sanitized to #{inspect(result)}, which still traverses"

        # The clause the example tests never stated. `""` and `"."` sanitize to
        # themselves and both resolve to `@upload_dir` itself rather than to a
        # path strictly beneath it, so "stays under" cannot mean strict descent:
        # a filename that resolves to the directory is not an escape, it is a
        # caller-level emptiness bug. Escaping is what this asserts.
        expanded = Path.expand(Path.join(@upload_dir, result))

        assert expanded == @upload_dir or String.starts_with?(expanded, @upload_dir <> "/"),
               "#{inspect(filename)} sanitized to #{inspect(result)}, which resolves to " <>
                 "#{inspect(expanded)}, outside #{@upload_dir}"
      end
    end
  end

  # A filename as a browser may send it: hostile fragments concatenated, with raw
  # byte runs mixed in so the generator is not limited to the shapes listed.
  defp filename do
    gen all(
          parts <-
            list_of(
              frequency([
                {6, member_of(@fragments)},
                {1, binary(max_length: 4)}
              ]),
              max_length: 6
            )
        ) do
      IO.iodata_to_binary(parts)
    end
  end
end
