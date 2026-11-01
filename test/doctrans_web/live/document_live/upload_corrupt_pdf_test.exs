defmodule DoctransWeb.DocumentLive.UploadCorruptPdfTest do
  @moduledoc """
  Covers the one upload the magic-byte check cannot catch.

  `Doctrans.Validation.validate_file_content/2` reads eight bytes, so a file that
  begins `%PDF-` and continues with anything at all is accepted and stored. The
  only thing that can tell the difference is poppler, so this drives such a file
  through the real upload *and* the real extractor — not the stub the
  neighbouring upload tests pin — and the rejection comes from `pdfinfo` failing
  to read the garbage body.

  What is being asserted is that the failure lands somewhere the user can see it:
  the document ends in `error` with the diagnostic recorded, its card says so,
  and no page was created that a later stage could mistake for a success.
  """
  # Sync: the test mounts the dashboard, whose PubSub is global, and overrides
  # the global `:uploads` application env.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Layout
  alias Doctrans.Processing.{PdfExtractor, PdfExtractorMock}
  alias Doctrans.TestEnv

  # Both the extractor and the extraction job log the poppler diagnostic.
  @moduletag :capture_log

  setup do
    directory = Path.join(System.tmp_dir!(), "upload-corrupt-#{Uniq.UUID.uuid7()}")
    File.mkdir_p!(directory)

    TestEnv.put_env(:uploads,
      upload_dir: directory,
      max_file_size: 100_000
    )

    # The real extractor behind the mock the suite installs by default: the
    # point of this file is that poppler is what refuses the document.
    Mox.stub_with(PdfExtractorMock, PdfExtractor)

    on_exit(fn -> File.rm_rf!(directory) end)

    %{directory: directory}
  end

  test "a PDF with valid magic bytes and a garbage body fails the document at pdfinfo", %{
    conn: conn,
    directory: directory
  } do
    content = corrupt_pdf()

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#upload-document-btn") |> render_click()

    upload =
      file_input(view, "#upload-form", :document, [
        %{name: "corrupt.pdf", content: content, type: "application/pdf"}
      ])

    render_upload(upload, "corrupt.pdf")
    view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

    # The content check passed on the header alone, so the upload itself was
    # accepted and the file was stored byte for byte.
    assert [document] = Documents.list_documents()
    refute has_element?(view, ~s{[data-failed-upload="corrupt.pdf"]})
    assert File.ls!(Path.join(directory, "documents")) == [document.id]

    stored =
      document.id
      |> Layout.document_dir()
      |> Path.join("original.pdf")
      |> File.read!()

    assert stored == content

    # Extraction runs inline, so by the time the dashboard re-renders the
    # document has already been through poppler and failed.
    assert document.status == "error"
    assert_pdfinfo_failure(document.error_message)

    # Nothing was extracted, so there is no half-built page for a later stage to
    # read as a success.
    assert document.total_pages == nil
    assert Documents.list_pages(document.id) == []

    # And the failure is on the card rather than only in the database. No page
    # failed, because none was ever rendered, so the whole-document wording is
    # what the user gets.
    failure = "#document-progress-#{document.id}-failure"

    assert has_element?(view, "#{failure}[data-failed-pages='']")

    assert has_element?(
             view,
             failure,
             "Processing failed. You can reprocess the document when its jobs have finished."
           )
  end

  # With poppler installed the command runs and its own diagnostic is what was
  # recorded; without it the call never reaches the command and the recorded
  # reason names what is missing instead. Which applies is a property of the
  # machine, not of the upload, so the test establishes it rather than accepting
  # either.
  defp assert_pdfinfo_failure(error_message) do
    assert error_message =~ "pdf_extraction_failed"

    if PdfExtractor.available?() do
      assert error_message =~ "pdfinfo_failed"
    else
      assert error_message =~ "poppler_not_found"
      assert error_message =~ "pdfinfo"
    end
  end

  # Valid `%PDF-` magic bytes -- eight bytes is all `validate_file_content/2`
  # reads -- followed by bytes that are not a PDF body at all.
  defp corrupt_pdf, do: "%PDF-1.7\n" <> String.duplicate(<<0xDE, 0xAD, 0xBE, 0xEF>>, 64)
end
