defmodule Doctrans.Processing.PdfExtractorTest do
  @moduledoc """
  Covers the extractor's filesystem helpers and what each poppler-backed call
  reports for a PDF that is not there.

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
  it controls. They need `Application.put_env/3`, so they cannot live in this
  async file.
  """

  use ExUnit.Case, async: true

  alias Doctrans.Processing.PdfExtractor

  # The extractor logs every poppler failure with its diagnostic tail.
  @moduletag :capture_log

  @missing_pdf "/nonexistent.pdf"

  describe "list_page_images/1" do
    test "returns empty list for non-existent directory" do
      result = PdfExtractor.list_page_images("/nonexistent/directory")
      assert result == []
    end

    test "returns sorted list of page images" do
      dir = tmp_dir("pdf_test")

      # Create test files out of order
      File.write!(Path.join(dir, "page-03.png"), "")
      File.write!(Path.join(dir, "page-01.png"), "")
      File.write!(Path.join(dir, "page-02.png"), "")

      result = PdfExtractor.list_page_images(dir)

      assert length(result) == 3
      assert Enum.at(result, 0) =~ "page-01.png"
      assert Enum.at(result, 1) =~ "page-02.png"
      assert Enum.at(result, 2) =~ "page-03.png"
    end
  end

  describe "page_image_path/2" do
    test "returns nil for non-existent page" do
      dir = tmp_dir("pdf_test")

      result = PdfExtractor.page_image_path(dir, 1)
      assert result == nil
    end

    test "returns path for existing page" do
      dir = tmp_dir("pdf_test")
      File.write!(Path.join(dir, "page-01.png"), "")

      result = PdfExtractor.page_image_path(dir, 1)
      assert result =~ "page-01.png"
    end
  end

  describe "extract_pages/3" do
    test "reports a missing PDF without creating the output directory" do
      dir = tmp_dir("pdf_out")
      File.rm_rf!(dir)

      assert {:error, reason} = PdfExtractor.extract_pages(@missing_pdf, dir)
      assert_missing_pdf_reason(reason, :pdfinfo_failed, "pdfinfo")

      # The page count is taken before anything is written, so a document that
      # cannot even be opened leaves no half-built pages directory behind.
      refute File.exists?(dir)
    end
  end

  describe "extract_page/4" do
    test "reports a missing PDF as a renderer failure" do
      dir = tmp_dir("pdf_out")

      assert {:error, reason} = PdfExtractor.extract_page(@missing_pdf, dir, 1)
      assert_missing_pdf_reason(reason, :pdf_command_failed, "pdftoppm")

      # Nothing was rendered, so nothing is there for a retry to mistake for a
      # finished page.
      assert PdfExtractor.list_page_images(dir) == []
    end
  end

  describe "get_page_count/1" do
    test "reports a missing PDF as a pdfinfo failure" do
      assert {:error, reason} = PdfExtractor.get_page_count(@missing_pdf)
      assert_missing_pdf_reason(reason, :pdfinfo_failed, "pdfinfo")
    end
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
