defmodule Doctrans.Processing.PdfExtractorTest do
  @moduledoc """
  Covers what each poppler-backed call reports for a PDF that is not there.

  The three error tests below used to wrap the call in `rescue ErlangError ->
  :ok`, which turned any crash — including one from a completely unrelated
  defect — into a pass. The extractor does not raise for a missing file: poppler
  reports the file it could not open and exits non-zero, and the extractor
  passes that diagnostic through under the tag of the command that produced it.
  On a machine without poppler the command never runs and the error names it
  instead. Both outcomes are asserted exactly here, and a raise now fails.

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

  describe "extract_page/4" do
    test "reports a missing PDF as a renderer failure" do
      dir = tmp_dir("pdf_out")

      assert {:error, reason} = PdfExtractor.extract_page(@missing_pdf, dir, 1)
      assert_missing_pdf_reason(reason, :pdf_command_failed, "pdftoppm")

      # Nothing was rendered, so nothing is there for a retry to mistake for a
      # finished page.
      assert Path.wildcard(Path.join(dir, "page-*.png")) == []
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
    @tag :tmp_dir
    test "a crafted PDF is measured by its pages, not by its metadata", %{tmp_dir: tmp_dir} do
      if PdfExtractor.available?() do
        pdf = Path.join(tmp_dir, "crafted.pdf")
        File.write!(pdf, crafted_pdf())

        assert {:error, {:pdf_page_too_large, bindings}} = PdfExtractor.get_page_count(pdf)
        assert bindings[:page_number] == 2
      end
    end
  end

  # A minimal two-page PDF with an Info dictionary whose title and subject
  # carry the lines a spoof would want pdfinfo to print ahead of the real ones.
  defp crafted_pdf do
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 14400 14400] >>",
      "<< /Title (spoof\\nPage size: 1 x 1 pts\\nPages: 1) /Subject (Page size: 2 x 2 pts) >>"
    ]

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
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R /Info 5 0 R >>\n" <>
      "startxref\n#{byte_size(body)}\n%%EOF\n"
  end

  # With poppler installed the command runs and its own diagnostic comes back
  # under `tag`; without it the call never reaches the command and the error
  # names what is missing. Which of the two applies is a property of the machine,
  # not of the call, so the test establishes it rather than accepting either.
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
