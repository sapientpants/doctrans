defmodule DoctransWeb.DocumentLive.UploadValidationTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents

  @moduletag :capture_log
  @size_limit 64

  setup do
    previous_uploads = Application.fetch_env!(:doctrans, :uploads)
    previous_extractor = Application.fetch_env!(:doctrans, :pdf_extractor_module)
    directory = Path.join(System.tmp_dir!(), "upload-validation-#{Uniq.UUID.uuid7()}")
    File.mkdir_p!(directory)

    Application.put_env(:doctrans, :uploads,
      upload_dir: directory,
      max_file_size: @size_limit
    )

    Application.put_env(:doctrans, :pdf_extractor_module, Doctrans.UploadPathExtractorStub)

    on_exit(fn ->
      Application.put_env(:doctrans, :uploads, previous_uploads)
      Application.put_env(:doctrans, :pdf_extractor_module, previous_extractor)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  for extension <- ~w(pdf docx doc odt rtf) do
    @extension extension
    test "rejects mismatched magic bytes for .#{extension} before storing a document", %{
      conn: conn,
      directory: directory
    } do
      {view, upload, filename} =
        prepare_upload(conn, "fake.#{@extension}", "not a document header")

      render_upload(upload, filename)
      view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Documents.list_documents() == []
      assert File.ls!(directory) == []
    end
  end

  for size <- [@size_limit - 1, @size_limit] do
    @size size
    test "accepts a PDF of #{size} bytes", %{conn: conn} do
      content = pdf_content(@size)
      {view, upload, filename} = prepare_upload(conn, "boundary.pdf", content)
      render_upload(upload, filename)
      view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

      [document] = Documents.list_documents()
      assert has_element?(view, "#documents-#{document.id}")

      stored_content =
        document.id
        |> Documents.document_upload_dir()
        |> Path.join("original.pdf")
        |> File.read!()

      assert stored_content == content
    end
  end

  test "rejects an upload one byte above the advertised limit", %{conn: conn, directory: dir} do
    {_view, upload, filename} = prepare_upload(conn, "large.pdf", pdf_content(@size_limit + 1))

    assert {:error, [[_, :too_large]]} = render_upload(upload, filename)
    assert Documents.list_documents() == []
    assert File.ls!(dir) == []
  end

  test "rechecks the disk size when consuming an otherwise accepted upload", %{
    conn: conn,
    directory: directory
  } do
    {view, upload, filename} = prepare_upload(conn, "large.pdf", pdf_content(@size_limit))
    render_upload(upload, filename)

    # Lower the server limit after upload to exercise the independent on-disk check,
    # without LiveView's upload preflight rejecting the entry first.
    Application.put_env(:doctrans, :uploads,
      upload_dir: directory,
      max_file_size: @size_limit - 1
    )

    view |> form("#upload-form", %{target_language: "en"}) |> render_submit()

    assert has_element?(view, "#flash-error")
    assert Documents.list_documents() == []
    assert File.ls!(directory) == []
  end

  defp prepare_upload(conn, filename, content) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#upload-document-btn") |> render_click()

    upload =
      file_input(view, "#upload-form", :document, [
        %{name: filename, content: content, type: "application/octet-stream"}
      ])

    {view, upload, filename}
  end

  defp pdf_content(size), do: "%PDF-1.7\n" <> String.duplicate("x", size - 9)
end
