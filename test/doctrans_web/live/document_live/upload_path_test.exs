defmodule DoctransWeb.DocumentLive.UploadPathTest do
  # Sync: every test mounts the dashboard, whose PubSub is global.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Layout
  alias Doctrans.Processing.{DocumentConverterMocks, PdfExtractorMock, Run}

  @moduletag :capture_log

  setup do
    # Keep the uploaded original on disk for the containment assertions.
    Mox.stub(PdfExtractorMock, :get_page_count, fn _path -> {:error, :invalid_pdf} end)
    :ok
  end

  for filename <- [
        "../../etc/x.pdf",
        "/etc/x.pdf",
        "..\\..\\etc\\x.pdf",
        "C:\\Windows\\x.pdf",
        "nul\0name.pdf",
        "．．／資料∕Übersetzung.pdf",
        "../../etc/x.PDF",
        "report..pdf"
      ] do
    @filename filename

    test "stores #{inspect(filename)} inside its generated document directory", %{conn: conn} do
      filename = @filename
      content = "%PDF-1.7\npath containment test"
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#upload-document-btn") |> render_click()

      upload =
        file_input(view, "#upload-form", :document, [
          %{name: filename, content: content, type: "application/pdf"}
        ])

      render_upload(upload, filename)
      view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

      [document] = Documents.list_documents()
      directory = Layout.document_dir(document.id)
      on_exit(fn -> File.rm_rf!(directory) end)

      assert {:ok, _uuid} = Ecto.UUID.cast(document.id)
      assert Path.relative_to(directory, Layout.root()) == "documents/#{document.id}"
      assert Enum.sort(File.ls!(directory)) == ["original.pdf", "runs"]
      assert File.read!(Path.join(directory, "original.pdf")) == content
      assert document.source_extension == ".pdf"
      assert Run.source_available?(document)
      refute String.contains?(document.original_filename, ["/", "\\", "\0"])
      refute String.contains?(document.title, "\0")
      assert has_element?(view, "#documents-#{document.id}")
    end
  end

  test "titles a .docx upload by its root name and keeps its own extension", %{conn: conn} do
    # The converter is what would run next; a missing LibreOffice stops the job
    # without depending on whether this machine has one installed.
    DocumentConverterMocks.missing()
    filename = "Quarterly_Report.docx"
    content = <<0x50, 0x4B, 0x03, 0x04>> <> "docx title test"
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#upload-document-btn") |> render_click()

    upload =
      file_input(view, "#upload-form", :document, [
        %{name: filename, content: content, type: "application/octet-stream"}
      ])

    render_upload(upload, filename)
    view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

    [document] = Documents.list_documents()
    directory = Layout.document_dir(document.id)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert document.title == "Quarterly Report"
    assert document.original_filename == filename
    assert document.source_extension == ".docx"
    assert File.read!(Path.join(directory, "original.docx")) == content
    assert has_element?(view, "#documents-#{document.id}")
  end
end
