defmodule DoctransWeb.DocumentLive.ReprocessingTest do
  use DoctransWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Doctrans.Fixtures
  alias Doctrans.Documents
  alias Doctrans.Processing.Run

  setup do
    previous = Application.fetch_env!(:doctrans, :openai)
    bypass = Bypass.open()

    Application.put_env(
      :doctrans,
      :openai,
      Keyword.put(previous, :base_url, "http://localhost:#{bypass.port}")
    )

    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "vision"}, %{id: "translation"}]}))
    end)

    on_exit(fn -> Application.put_env(:doctrans, :openai, previous) end)
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_fixture(document, %{extraction_status: "completed", translation_status: "completed"})
    directory = Documents.document_upload_dir(document.id)
    File.mkdir_p!(directory)
    File.write!(Run.source_path(document), "original pdf")
    on_exit(fn -> File.rm_rf(directory) end)
    %{document: document}
  end

  test "document confirmation resets progress in two viewers and survives reload", %{
    conn: conn,
    document: document
  } do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      {:ok, other, _} = live(conn, ~p"/documents/#{document.id}")

      :sys.replace_state(view.pid, fn state ->
        Process.put(:oban_testing, :manual)
        state
      end)

      refute has_element?(view, "#document-processing-progress")
      view |> element("#show-document-reprocess") |> render_click()
      assert has_element?(view, "#document-reprocess-form")
      model = "vision"

      view
      |> form("#document-reprocess-form", %{extraction_model: model, translation_model: model})
      |> render_submit()

      refute has_element?(view, "#reprocess-modal")
      assert has_element?(view, "#document-processing-progress progress[value='0.0']")
      assert has_element?(other, "#document-processing-progress progress[value='0.0']")
      assert has_element?(view, "#show-document-reprocess[disabled]")
      assert Documents.list_pages(document.id) == []
      {:ok, reloaded, _} = live(conn, ~p"/documents/#{document.id}")
      assert has_element?(reloaded, "#document-processing-progress progress[value='0.0']")
    end)
  end

  test "missing original disables reprocessing and cancel leaves generated pages intact", %{
    conn: conn,
    document: document
  } do
    {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
    view |> element("#show-document-reprocess") |> render_click()
    view |> element("#reprocess-cancel") |> render_click()
    assert length(Documents.list_pages(document.id)) == 1
    File.rm!(Run.source_path(document))
    {:ok, missing, _} = live(conn, ~p"/documents/#{document.id}")
    assert has_element?(missing, "#show-document-reprocess[disabled]")
    refute has_element?(missing, "#original-upload-missing")
    refute has_element?(missing, "#page-processing-models")
  end
end
