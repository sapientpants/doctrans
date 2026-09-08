defmodule DoctransWeb.DocumentLive.UploadPathTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents

  @moduletag :capture_log

  setup do
    previous = Application.fetch_env!(:doctrans, :pdf_extractor_module)

    Application.put_env(
      :doctrans,
      :pdf_extractor_module,
      Doctrans.UploadPathExtractorStub
    )

    on_exit(fn -> Application.put_env(:doctrans, :pdf_extractor_module, previous) end)
  end

  for filename <- [
        "../../etc/x.pdf",
        "/etc/x.pdf",
        "..\\..\\etc\\x.pdf",
        "C:\\Windows\\x.pdf",
        "nul\0name.pdf",
        "．．／資料∕Übersetzung.pdf",
        "../../etc/x.PDF"
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
      directory = Documents.document_upload_dir(document.id)
      on_exit(fn -> File.rm_rf!(directory) end)

      assert {:ok, _uuid} = Ecto.UUID.cast(document.id)
      assert Path.relative_to(directory, Documents.uploads_dir()) == "documents/#{document.id}"
      assert Enum.sort(File.ls!(directory)) == ["original.pdf", "pages"]
      assert File.read!(Path.join(directory, "original.pdf")) == content
      refute String.contains?(document.original_filename, ["/", "\\", "\0"])
      refute String.contains?(document.title, "\0")
      assert has_element?(view, "#documents-#{document.id}")
    end
  end
end
