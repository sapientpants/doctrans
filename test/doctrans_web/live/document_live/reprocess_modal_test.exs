defmodule DoctransWeb.DocumentLive.ReprocessModalTest do
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents

  setup do
    previous = Application.fetch_env!(:doctrans, :openai)
    bypass = Bypass.open()

    Application.put_env(
      :doctrans,
      :openai,
      Keyword.put(previous, :base_url, "http://localhost:#{bypass.port}")
    )

    on_exit(fn -> Application.put_env(:doctrans, :openai, previous) end)
    %{bypass: bypass}
  end

  test "model selections survive reopening and the page is reprocessed", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "vision"}, %{id: "translation"}]}))
    end)

    document = document_fixture(%{total_pages: 1})
    page = completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()

    view
    |> form("#reprocess-form", extraction_model: "vision", translation_model: "translation")
    |> render_change()

    view |> element("#reprocess-cancel") |> render_click()
    refute has_element?(view, "#reprocess-modal")

    view |> element("#show-reprocess") |> render_click()
    assert has_element?(view, "#extraction-model-select option[value='vision'][selected]")
    assert has_element?(view, "#translation-model-select option[value='translation'][selected]")

    view
    |> form("#reprocess-form", extraction_model: "vision", translation_model: "translation")
    |> render_submit()

    refute has_element?(view, "#reprocess-modal")
    reprocessed = Documents.get_page!(page.id)
    assert reprocessed.extraction_status == "completed"
    assert reprocessed.original_markdown != page.original_markdown
    assert reprocessed.translated_markdown != page.translated_markdown
  end

  test "model fetch failure leaves an error and disables submission", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      Plug.Conn.resp(conn, 401, "unauthorized")
    end)

    document = document_fixture(%{total_pages: 1})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()

    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-submit-btn[disabled]")
    refute has_element?(view, "#extraction-model-select[disabled]")
  end
end
