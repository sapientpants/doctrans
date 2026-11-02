defmodule DoctransWeb.DocumentLive.ReprocessingTest do
  use DoctransWeb.ConnCase, async: true
  import Doctrans.Fixtures
  alias Doctrans.Documents
  alias Doctrans.Documents.Layout
  alias Doctrans.Processing.{OpenAIMock, Run}

  setup do
    # The dialog's model list is the mock's answer: the fetch runs in a task the
    # LiveView under test spawned, which carries this test's stubs (#193).
    Mox.stub(OpenAIMock, :list_models, fn -> {:ok, ["vision", "translation"]} end)

    document = document_fixture(%{status: "completed", total_pages: 1})
    page_fixture(document, %{extraction_status: "completed", translation_status: "completed"})
    directory = Layout.document_dir(document.id)
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
      render_async(view)
      assert has_element?(view, "#document-reprocess-form")
      model = "vision"

      # Submitting a model the selects do not offer fails inside `form/3`, which
      # would report the submit rather than the model list that never arrived.
      refute has_element?(view, "#reprocess-model-error")
      assert has_element?(view, "#extraction-model-select option[value='#{model}']")
      assert has_element?(view, "#translation-model-select option[value='#{model}']")

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
    render_async(view)
    view |> element("#reprocess-cancel") |> render_click()
    assert length(Documents.list_pages(document.id)) == 1
    File.rm!(Run.source_path(document))
    {:ok, missing, _} = live(conn, ~p"/documents/#{document.id}")
    assert has_element?(missing, "#show-document-reprocess[disabled]")
    refute has_element?(missing, "#original-upload-missing")
  end
end
