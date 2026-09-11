defmodule DoctransWeb.DocumentLive.ReprocessModalTest do
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.{Config, Documents}
  alias Doctrans.Documents.Pages

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

  test "opening restores the page's recorded models and the page is reprocessed", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{data: [%{id: "vision"}, %{id: "translation"}, %{id: "alternative"}]})
      )
    end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    page = completed_page_fixture(document)
    {:ok, page} = Pages.update_page_extraction(page, %{extraction_model: "vision"})
    {:ok, page} = Pages.update_page_translation(page, %{translation_model: "translation"})
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert has_element?(view, "#extraction-model-select option[value='vision'][selected]")
    assert has_element?(view, "#translation-model-select option[value='translation'][selected]")

    view
    |> form("#reprocess-form", extraction_model: "alternative", translation_model: "alternative")
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

  test "pages without model history use configured defaults", %{conn: conn, bypass: bypass} do
    extraction = Config.OpenAI.vision_model()
    translation = Config.OpenAI.translation_model()

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{data: Enum.map(Enum.uniq([extraction, translation]), &%{id: &1})})
      )
    end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    view |> element("#show-reprocess") |> render_click()

    assert has_element?(view, "#extraction-model-select option[value='#{extraction}'][selected]")

    assert has_element?(
             view,
             "#translation-model-select option[value='#{translation}'][selected]"
           )
  end

  test "embedding models are excluded from both model lists", %{conn: conn, bypass: bypass} do
    previous = Application.get_env(:doctrans, :embedding)
    Application.put_env(:doctrans, :embedding, model: "custom-vector-model")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:doctrans, :embedding, previous),
        else: Application.delete_env(:doctrans, :embedding)
    end)

    models = ["vision", "text-embedding-3-small", "Qwen3-Embedding-8B", "custom-vector-model"]

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: Enum.map(models, &%{id: &1})}))
    end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    view |> element("#show-reprocess") |> render_click()

    for selector <- ["#extraction-model-select", "#translation-model-select"] do
      assert has_element?(view, "#{selector} option[value='vision']")

      for model <- tl(models) do
        refute has_element?(view, "#{selector} option[value='#{model}']")
      end
    end
  end

  test "model fetch failure leaves an error and disables submission", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      Plug.Conn.resp(conn, 401, "unauthorized")
    end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()

    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-submit-btn[disabled]")
    refute has_element?(view, "#extraction-model-select[disabled]")
  end
end
