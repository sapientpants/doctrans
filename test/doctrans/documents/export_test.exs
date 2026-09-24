defmodule Doctrans.Documents.ExportTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.{Document, Export, Page}

  describe "markdown/1 header" do
    test "names the document, its source file and both languages" do
      markdown = Export.markdown(document(pages: [translated_page(1)]))

      assert markdown =~ "# Quarterly Report"
      assert markdown =~ "- **Source file:** quarterly-report.pdf"
      assert markdown =~ "- **Translation:** fr → en"
    end

    test "reports an undetected source language as unknown" do
      markdown = Export.markdown(document(source_language: nil, pages: [translated_page(1)]))

      assert markdown =~ "- **Translation:** unknown → en"
    end

    test "stamps the export with a truncated UTC timestamp" do
      before = DateTime.utc_now() |> DateTime.truncate(:second)
      markdown = Export.markdown(document(pages: []))
      after_export = DateTime.utc_now() |> DateTime.truncate(:second)

      [_line, stamp] = Regex.run(~r/- \*\*Exported:\*\* (\S+)$/m, markdown)

      assert {:ok, exported_at, 0} = DateTime.from_iso8601(stamp)
      assert exported_at.microsecond == {0, 0}
      assert DateTime.compare(exported_at, before) in [:eq, :gt]
      assert DateTime.compare(exported_at, after_export) in [:eq, :lt]
    end

    test "explains page boundaries and the meaning of model names" do
      markdown = Export.markdown(document(pages: [translated_page(1)]))

      assert markdown =~ "Each `## Page N` heading below marks a page boundary"
      assert markdown =~ "may not identify the\nexact weights used."
    end
  end

  describe "markdown/1 with a mix of page outcomes" do
    setup do
      pages = [
        translated_page(1),
        failed_page(2),
        pending_page(3),
        blank_page(4),
        translated_page(5)
      ]

      %{markdown: Export.markdown(document(pages: pages))}
    end

    test "renders one heading per page, in page order", %{markdown: markdown} do
      assert Regex.scan(~r/^## Page (\d+)$/m, markdown) |> Enum.map(&List.last/1) ==
               ["1", "2", "3", "4", "5"]
    end

    test "separates every page with a horizontal rule", %{markdown: markdown} do
      assert length(Regex.scan(~r/^---$/m, markdown)) == 5
    end

    test "marks a failed page with both stage statuses", %{markdown: markdown} do
      assert markdown =~
               "> **Not translated: this page failed.** Extraction: error. Translation: pending."
    end

    test "marks an untranslated page with both stage statuses", %{markdown: markdown} do
      assert markdown =~
               "> **Not translated yet.** Extraction: completed. Translation: pending."
    end

    test "marks a page that completed with no content", %{markdown: markdown} do
      assert markdown =~ "> **Translated as empty.** This page produced no content."
    end

    test "counts agree with the notes rendered in the body", %{markdown: markdown} do
      assert markdown =~
               "- **Pages:** 5 total · 2 translated · 1 failed · 2 not yet translated"
    end

    test "ends with exactly one trailing newline", %{markdown: markdown} do
      refute String.ends_with?(markdown, "\n\n")
      assert String.ends_with?(markdown, "\n")
    end
  end

  describe "markdown/1 page content" do
    test "renders translated markdown verbatim" do
      body = "## Heading\n\n- item with *emphasis* and `code`\n\n| a | b |\n| - | - |"

      markdown =
        Export.markdown(document(pages: [%{translated_page(1) | translated_markdown: body}]))

      assert markdown =~ body
    end

    test "normalises CRLF line endings to LF" do
      page = %{translated_page(1) | translated_markdown: "first\r\nsecond\r\nthird"}

      markdown = Export.markdown(document(pages: [page]))

      refute markdown =~ "\r"
      assert markdown =~ "first\nsecond\nthird"
    end

    test "trims whitespace surrounding the page content" do
      page = %{translated_page(1) | translated_markdown: "\n\n   Body text   \n\n\n"}

      markdown = Export.markdown(document(pages: [page]))

      assert markdown =~ "## Page 1\n\nBody text\n"
      refute markdown =~ "Body text   "
    end

    test "uses each page's own number rather than its position in the list" do
      pages = [translated_page(7), translated_page(2), translated_page(30)]

      markdown = Export.markdown(document(pages: pages))

      assert Regex.scan(~r/^## Page (\d+)$/m, markdown) |> Enum.map(&List.last/1) ==
               ["2", "7", "30"]
    end
  end

  describe "markdown/1 provenance" do
    test "names both models when both were recorded" do
      markdown = Export.markdown(document(pages: [translated_page(1)]))

      assert markdown =~ "_Extracted with `qwen3-vl`; translated with `qwen3`._"
    end

    test "names only the extraction model when translation recorded none" do
      page = %{translated_page(1) | translation_model: nil}

      markdown = Export.markdown(document(pages: [page]))

      assert markdown =~ "_Extracted with `qwen3-vl`._"
      refute markdown =~ "translated with"
    end

    test "names only the translation model when extraction recorded none" do
      page = %{translated_page(1) | extraction_model: nil}

      markdown = Export.markdown(document(pages: [page]))

      assert markdown =~ "_Translated with `qwen3`._"
      refute markdown =~ "Extracted with"
    end

    test "omits the line entirely when neither model was recorded" do
      page = %{translated_page(1) | extraction_model: nil, translation_model: nil}

      markdown = Export.markdown(document(pages: [page]))

      refute markdown =~ "Extracted with"
      refute markdown =~ "Translated with"
    end

    test "is not attached to a page without content" do
      page = %{failed_page(2) | extraction_model: "qwen3-vl", translation_model: "qwen3"}

      markdown = Export.markdown(document(pages: [page]))

      refute markdown =~ "Extracted with"
    end
  end

  describe "markdown/1 with no pages" do
    setup do
      %{markdown: Export.markdown(document(pages: []))}
    end

    test "keeps the header", %{markdown: markdown} do
      assert markdown =~ "# Quarterly Report"
      assert markdown =~ "- **Pages:** 0 total · 0 translated · 0 failed · 0 not yet translated"
    end

    test "says so instead of rendering an empty body", %{markdown: markdown} do
      assert markdown =~ "---\n\n_This document has no pages._\n"
      refute markdown =~ ~r/^## Page \d/m
    end
  end

  describe "markdown/1 argument handling" do
    setup do
      # Handed over through the context so the compiler's type checker cannot
      # see the unloaded association and warn about the call it is meant to make.
      %{unloaded: %Document{title: "Unloaded"}}
    end

    test "refuses a document whose pages were never loaded", %{unloaded: document} do
      assert_raise FunctionClauseError, fn -> Export.markdown(document) end
    end
  end

  describe "filename/1" do
    test "derives the name from an ordinary title" do
      assert Export.filename(document(title: "Quarterly Report")) == "Quarterly Report.md"
    end

    test "neutralises path separators and parent directory traversal" do
      filename = Export.filename(document(title: "../../etc/passwd"))

      refute filename =~ "/"
      refute filename =~ ".."
      assert String.ends_with?(filename, ".md")
    end

    test "removes null bytes and control characters" do
      # Built from bytes rather than typed literally: control characters in a
      # source file are invisible and easily lost to an editor or a formatter.
      title = "re" <> <<0>> <> "port" <> <<0x7F, 0x01>> <> " v2\n"

      filename = Export.filename(document(title: title))

      refute filename =~ "\0"
      refute filename =~ ~r/[[:cntrl:]]/
      assert String.ends_with?(filename, ".md")
    end

    test "keeps quotes out of the content disposition header" do
      filename = Export.filename(document(title: ~s(a "quoted" title)))

      refute filename =~ "\""
    end

    test "collapses whitespace runs and trims the edges" do
      assert Export.filename(document(title: "  spaced    out  title  ")) ==
               "spaced out title.md"
    end

    test "caps a very long title at 100 characters plus the extension" do
      filename = Export.filename(document(title: String.duplicate("ab", 200)))

      assert String.length(filename) == 103
      assert String.ends_with?(filename, ".md")
    end

    test "cuts a long title on a codepoint boundary" do
      filename = Export.filename(document(title: String.duplicate("é", 150)))

      assert String.valid?(filename)
      assert filename == String.duplicate("é", 100) <> ".md"
    end

    test "falls back to a fixed stem when nothing usable survives" do
      assert Export.filename(document(title: "   ")) == "document.md"
      assert Export.filename(document(title: "")) == "document.md"
      assert Export.filename(document(title: nil)) == "document.md"
    end
  end

  defp document(overrides) do
    defaults = %Document{
      id: Ecto.UUID.generate(),
      title: "Quarterly Report",
      original_filename: "quarterly-report.pdf",
      source_language: "fr",
      target_language: "en",
      total_pages: 5
    }

    struct!(defaults, overrides)
  end

  defp page(number, overrides) do
    defaults = %Page{
      page_number: number,
      extraction_status: "completed",
      translation_status: "pending"
    }

    struct!(defaults, overrides)
  end

  defp translated_page(number) do
    page(number,
      translated_markdown: "Page #{number} body.",
      translation_status: "completed",
      extraction_model: "qwen3-vl",
      translation_model: "qwen3"
    )
  end

  defp failed_page(number), do: page(number, extraction_status: "error")

  defp pending_page(number), do: page(number, [])

  defp blank_page(number),
    do: page(number, translated_markdown: "   \n", translation_status: "completed")
end
