defmodule DoctransWeb.DocumentLive.ConfigTest do
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  test "reprocess selections use configured vision and translation models", %{conn: conn} do
    previous = Application.fetch_env!(:doctrans, :openai)
    bypass = Bypass.open()

    Application.put_env(:doctrans, :openai,
      base_url: "http://localhost:#{bypass.port}",
      vision_model: "custom-vision",
      chat_model: "custom-chat",
      translation_model: "custom-translation"
    )

    on_exit(fn -> Application.put_env(:doctrans, :openai, previous) end)

    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          data: Enum.map(~w(custom-vision custom-chat custom-translation), &%{id: &1})
        })
      )
    end)

    document = document_with_pages_fixture(%{}, 1)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    render_click(view, "show_reprocess_modal")

    assert has_element?(view, "#extraction-model-select option[value='custom-vision'][selected]")

    assert has_element?(
             view,
             "#translation-model-select option[value='custom-translation'][selected]"
           )
  end
end
