defmodule DoctransWeb.DocumentLive.ConfigTest do
  # Sync: the test overrides the global `:openai` application env, which is
  # where the configured model names are read from.
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Processing.OpenAIMock
  alias Doctrans.TestEnv

  test "reprocess selections use configured vision and translation models", %{conn: conn} do
    TestEnv.put_env(
      :openai,
      Keyword.merge(Application.fetch_env!(:doctrans, :openai),
        vision_model: "custom-vision",
        chat_model: "custom-chat",
        translation_model: "custom-translation"
      )
    )

    Mox.stub(OpenAIMock, :list_models, fn ->
      {:ok, ~w(custom-vision custom-chat custom-translation)}
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
