defmodule DoctransWeb.DocumentLive.ReprocessModalEmbeddingFilterTest do
  # Sync: the test overrides the global `:embedding` application env, which is
  # where the dialog reads the configured embedding model it must leave out.
  # Every other reprocess-modal test is async in `ReprocessModalTest`.
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Processing.OpenAIMock
  alias Doctrans.TestEnv

  test "embedding models are excluded from both model lists", %{conn: conn} do
    TestEnv.put_env(:embedding, model: "custom-vector-model")

    models = ["vision", "text-embedding-3-small", "Qwen3-Embedding-8B", "custom-vector-model"]
    Mox.stub(OpenAIMock, :list_models, fn -> {:ok, models} end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    view |> element("#show-reprocess") |> render_click()
    render_async(view)

    for selector <- ["#extraction-model-select", "#translation-model-select"] do
      assert has_element?(view, "#{selector} option[value='vision']")

      for model <- tl(models) do
        refute has_element?(view, "#{selector} option[value='#{model}']")
      end
    end
  end
end
