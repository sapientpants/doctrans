defmodule DoctransWeb.DocumentLive.ConfigTest do
  # Sync: the test overrides the global `:openai` application env.
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.TestEnv

  test "reprocess selections use configured vision and translation models", %{conn: conn} do
    bypass = Bypass.open()

    TestEnv.put_env(:openai,
      base_url: "http://localhost:#{bypass.port}",
      vision_model: "custom-vision",
      chat_model: "custom-chat",
      translation_model: "custom-translation"
    )

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
    render_async(view)

    assert has_element?(view, "#extraction-model-select option[value='custom-vision'][selected]")

    assert has_element?(
             view,
             "#translation-model-select option[value='custom-translation'][selected]"
           )
  end
end
