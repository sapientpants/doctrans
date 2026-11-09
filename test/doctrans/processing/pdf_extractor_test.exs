defmodule Doctrans.Processing.PdfExtractorTest do
  @moduledoc """
  Covers what each poppler-backed call reports for a PDF that is not there, and
  pins what real poppler prints and renders to what the fakes elsewhere assume.

  The error tests below used to wrap the call in `rescue ErlangError -> :ok`,
  which turned any crash — including one from a completely unrelated defect —
  into a pass. The extractor does not raise for a missing file: poppler reports
  the file it could not open and exits non-zero, and the extractor passes that
  diagnostic through under the tag of the command that produced it. On a machine
  without poppler the command never runs and the error names it instead. Both
  outcomes are asserted exactly here, and a raise now fails.

  Tests tagged `:poppler` need the real commands and are excluded by
  `test_helper.exs` on a machine without them, so the exclusion shows in the
  run's summary rather than passing vacuously.

  `available?/0` and the rest of the failure shapes — timeouts, the page, pixel
  and image-size limits, executable resolution — are covered deterministically
  in `Doctrans.Processing.PdfExtractorBoundsTest`, which pins poppler to fakes
  it controls. They override the application environment through
  `Doctrans.TestEnv`, so they cannot live in this async file.
  """

  use Doctrans.EnvCase, async: true

  alias Doctrans.Processing.PdfExtractor

  # The extractor logs every poppler failure with its diagnostic tail.
  @moduletag :capture_log

  @missing_pdf "/nonexistent.pdf"

  @letter "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"

  describe "extract_page/4" do
    test "reports a missing PDF from the first command that opens it" do
      dir = tmp_dir("pdf_out")

      assert {:error, reason} = PdfExtractor.extract_page(@missing_pdf, dir, 1)

      # The page is measured before it is rendered, so with poppler installed
      # pdfinfo is what fails to open the file. Without poppler the renderer is
      # resolved first and is what the error names: there is nothing to measure
      # for.
      assert_missing_pdf_reason(reason, :pdfinfo_failed, "pdftoppm")

      # Nothing was rendered, so nothing is there for a retry to mistake for a
      # finished page.
      assert Path.wildcard(Path.join(dir, "page-*.png")) == []
    end

    # The render is pinned to the measured pixel dimensions instead of being
    # left to a resolution; for an honest page that has to come out as the same
    # image `-r` would have given, or the pinning would change every render.
    @tag :poppler
    @tag :tmp_dir
    test "a pinned render has the dimensions the resolution would give", %{tmp_dir: tmp_dir} do
      pdf = Path.join(tmp_dir, "letter.pdf")
      File.write!(pdf, pdf_with_pages([@letter]))

      assert {:ok, path} = PdfExtractor.extract_page(pdf, Path.join(tmp_dir, "pages"), 1)

      # 612x792 pt at the default 150 dpi, rounded up as pdftoppm rounds.
      assert png_dimensions(path) == {1275, 1650}
    end
  end

  describe "get_page_count/1" do
    test "reports a missing PDF as a pdfinfo failure" do
      assert {:error, reason} = PdfExtractor.get_page_count(@missing_pdf)
      assert_missing_pdf_reason(reason, :pdfinfo_failed, "pdfinfo")
    end

    # The fakes in `PdfExtractorBoundsTest` pin down what the extractor does with
    # pdfinfo's output; this pins down that real pdfinfo output is what those
    # fakes say it is. A document whose first page is letter-sized, whose second
    # page is 200 inches square, and whose title spells out a small page size and
    # a page count of one, is rejected for its second page at the default limits.
    @tag :poppler
    @tag :tmp_dir
    test "a crafted PDF is measured by its pages, not by its metadata", %{tmp_dir: tmp_dir} do
      pdf = Path.join(tmp_dir, "crafted.pdf")

      File.write!(
        pdf,
        pdf_with_pages(
          [@letter, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 14400 14400] >>"],
          info:
            "<< /Title (spoof\\nPage size: 1 x 1 pts\\nPages: 1) /Subject (Page size: 2 x 2 pts) >>"
        )
      )

      assert {:error, {:pdf_page_too_large, bindings}} = PdfExtractor.get_page_count(pdf)
      assert bindings[:page_number] == 2
    end

    # pdfinfo prints dimensions with %g, so a page a million points on a side
    # prints as `1e+06 x 1e+06 pts`. That is the largest page a document can
    # ask for, and the one a digits-only pattern would have skipped.
    @tag :poppler
    @tag :tmp_dir
    test "a page pdfinfo prints in exponent notation is measured", %{tmp_dir: tmp_dir} do
      pdf = Path.join(tmp_dir, "exponent.pdf")

      File.write!(
        pdf,
        pdf_with_pages([
          @letter,
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1000000 1000000] >>"
        ])
      )

      assert {:error, {:pdf_page_too_large, bindings}} = PdfExtractor.get_page_count(pdf)
      assert bindings[:page_number] == 2
    end
  end

  # A minimal PDF with the given page objects and, optionally, an Info
  # dictionary.
  defp pdf_with_pages(pages, opts \\ []) do
    kids = pages |> Enum.with_index(3) |> Enum.map_join(" ", fn {_page, n} -> "#{n} 0 R" end)

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{length(pages)} >>"
      ] ++ pages ++ List.wrap(opts[:info])

    info_ref = if opts[:info], do: " /Info #{length(objects)} 0 R", else: ""

    serialize_pdf(objects, "<< /Size #{length(objects) + 1} /Root 1 0 R#{info_ref} >>")
  end

  # Numbers the objects from 1, writes the xref table their offsets make, and
  # closes with the trailer dictionary.
  defp serialize_pdf(objects, trailer) do
    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, number}, {acc, offsets} ->
        {acc <> "#{number} 0 obj\n#{object}\nendobj\n", [byte_size(acc) | offsets]}
      end)

    xref =
      Enum.map_join(Enum.reverse(offsets), "", fn offset ->
        String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n \n"
      end)

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      xref <>
      "trailer\n#{trailer}\n" <>
      "startxref\n#{byte_size(body)}\n%%EOF\n"
  end

  # Width and height from the PNG header: the IHDR chunk follows the 8-byte
  # signature, its 4-byte length and its 4-byte type.
  defp png_dimensions(path) do
    <<_signature_and_ihdr_head::binary-size(16), width::32, height::32, _rest::binary>> =
      File.read!(path)

    {width, height}
  end

  # With poppler installed the command runs and its own diagnostic comes back
  # under `tag`; without it the call never reaches a command and the error names
  # the first one the call resolves. Which of the two applies is a property of
  # the machine, not of the call, so the test establishes it rather than
  # accepting either.
  defp assert_missing_pdf_reason(reason, tag, command) do
    if PdfExtractor.available?() do
      assert {^tag, [error: diagnostic]} = reason
      assert diagnostic =~ @missing_pdf
    else
      assert reason == {:poppler_not_found, [command: command]}
    end
  end

  defp tmp_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
