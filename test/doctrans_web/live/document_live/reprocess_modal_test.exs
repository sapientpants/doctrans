defmodule DoctransWeb.DocumentLive.ReprocessModalTest do
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  alias Doctrans.{Config, Documents}
  alias Doctrans.Documents.{Pages, Topics}
  alias DoctransWeb.DocumentLive.ReprocessModal
  alias Phoenix.LiveView.Channel

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
    render_async(view)
    assert has_element?(view, "#extraction-model-select option[value='vision'][selected]")
    assert has_element?(view, "#translation-model-select option[value='translation'][selected]")

    view
    |> form("#reprocess-form", extraction_model: "alternative", translation_model: "alternative")
    |> render_change()

    view |> element("#reprocess-cancel") |> render_click()
    refute has_element?(view, "#reprocess-modal")

    view |> element("#show-reprocess") |> render_click()
    render_async(view)
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
    render_async(view)

    assert has_element?(view, "#extraction-model-select option[value='#{extraction}'][selected]")

    assert has_element?(
             view,
             "#translation-model-select option[value='#{translation}'][selected]"
           )
  end

  for unavailable_field <- [:extraction_model, :translation_model] do
    @unavailable_field unavailable_field
    test "unavailable historical #{@unavailable_field} requires an explicit selection", %{
      conn: conn,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "available"}]}))
      end)

      document = document_fixture(%{total_pages: 1, status: "completed"})
      page = completed_page_fixture(document)

      models =
        Map.put(
          %{extraction_model: "available", translation_model: "available"},
          @unavailable_field,
          "removed"
        )

      {:ok, page} = Pages.update_page_extraction(page, Map.take(models, [:extraction_model]))
      {:ok, _page} = Pages.update_page_translation(page, Map.take(models, [:translation_model]))
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      view |> element("#show-reprocess") |> render_click()
      render_async(view)

      for {field, model} <- models do
        selector =
          if field == :extraction_model,
            do: "#extraction-model-select",
            else: "#translation-model-select"

        expected = if model == "removed", do: "", else: model
        assert has_element?(view, "#{selector} option[value='#{expected}'][selected]")
      end

      assert has_element?(view, "#reprocess-submit-btn[disabled]")
      assert Documents.get_page!(page.id).original_markdown == page.original_markdown

      view
      |> form("#reprocess-form", extraction_model: "available", translation_model: "available")
      |> render_change()

      refute has_element?(view, "#reprocess-submit-btn[disabled]")

      view |> form("#reprocess-form") |> render_submit()

      refute has_element?(view, "#reprocess-modal")
      assert Documents.get_page!(page.id).original_markdown != page.original_markdown
    end
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
    render_async(view)

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
    render_async(view)

    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-submit-btn[disabled]")
    refute has_element?(view, "#extraction-model-select[disabled]")
  end

  # Long enough that a fetch running inside the LiveView process would trip the
  # per-test timeout below instead of merely making the test slow.
  @held_request_timeout 30_000

  defp two_page_document do
    document = document_fixture(%{total_pages: 2, status: "completed"})
    completed_page_fixture(document)

    completed_page_fixture(document, %{
      page_number: 2,
      image_path: "documents/#{document.id}/pages/page_2.png"
    })

    document
  end

  # Answers `/v1/models` with `responses` in order, holding the first one until
  # the test releases it. `Bypass.pass/1` keeps the verification pass quiet: the
  # LiveView abandons the held request as soon as its fetch is cancelled, and the
  # socket it kills takes the plug process with it once that process writes.
  defp hold_models_request(bypass, responses) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Bypass.pass(bypass)

    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        send(test_pid, {:models_requested, self()})

        receive do
          :release -> :ok
        after
          @held_request_timeout -> :ok
        end
      end

      models = Enum.at(responses, attempt - 1, List.last(responses))
      send(test_pid, {:models_responded, attempt})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: Enum.map(models, &%{id: &1})}))
    end)
  end

  # `Channel.async_pids/1` is what `render_async/1` itself calls to find the
  # tasks a LiveView is tracking; here it names the task so the test can watch
  # it die.
  defp async_task_pid(view) do
    {:ok, [pid]} = Channel.async_pids(view.pid)
    pid
  end

  # A cancelled task leaves the tracking map only once the LiveView has handled
  # its exit, so an empty list also means `handle_async/3` has already run.
  defp await_no_async(view, attempts \\ 100) do
    case Channel.async_pids(view.pid) do
      {:ok, []} ->
        :ok

      {:ok, pids} ->
        if attempts > 0 do
          Process.sleep(10)
          await_no_async(view, attempts - 1)
        else
          flunk("LiveView still tracks async tasks #{inspect(pids)}")
        end
    end
  end

  @tag timeout: 10_000
  test "an unanswered model fetch leaves the rest of the LiveView responsive", %{
    conn: conn,
    bypass: bypass
  } do
    hold_models_request(bypass, [["vision"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, handler}, 5_000

    # Everything below runs while the models request is still unanswered.
    assert has_element?(view, "#reprocess-modal")
    assert has_element?(view, "#extraction-model-select[disabled]")

    view |> element("#next-page") |> render_click()
    refute has_element?(view, "#previous-page[disabled]")

    {:ok, retitled} = Documents.update_document(document, %{title: "Still serving updates"})
    Topics.broadcast_document_update(retitled)
    assert render(view) =~ "Still serving updates"

    {:ok, page_two} =
      document.id
      |> Documents.get_page_by_number(2)
      |> Pages.update_page_extraction(%{
        extraction_status: "completed",
        original_markdown: "# Progress arrived"
      })

    Topics.broadcast_page_update(page_two)
    render_click(view, "toggle_original")
    assert render(view) =~ "Progress arrived"

    view |> element("header button[phx-click='toggle_chat']") |> render_click()
    assert has_element?(view, "#chat-messages")

    assert has_element?(view, "#reprocess-modal")
    view |> element("#reprocess-cancel") |> render_click()
    refute has_element?(view, "#reprocess-modal")

    send(handler, :release)
  end

  @tag timeout: 10_000
  test "closing the modal drops its fetch, and reopening asks again", %{
    conn: conn,
    bypass: bypass
  } do
    hold_models_request(bypass, [["stale-model"], ["fresh-model"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, handler}, 5_000
    held = async_task_pid(view)
    held_ref = Process.monitor(held)

    # Cancelling is not a failure, so it must not reach the error alert or the
    # log the genuine exit clause writes.
    log =
      capture_log(fn ->
        view |> element("#reprocess-cancel") |> render_click()
        assert_receive {:DOWN, ^held_ref, :process, ^held, _reason}, 5_000
        await_no_async(view)
      end)

    refute log =~ "Model fetch failed"
    refute has_element?(view, "#reprocess-modal")

    # The reopened modal asks again; only that newer answer may render.
    view |> element("#show-reprocess") |> render_click()
    render_async(view)
    assert_receive {:models_responded, 2}, 5_000
    assert has_element?(view, "#extraction-model-select option[value='fresh-model']")
    refute has_element?(view, "#reprocess-model-error")

    send(handler, :release)
    render_async(view)

    refute has_element?(view, "#extraction-model-select option[value='stale-model']")
    refute has_element?(view, "#translation-model-select option[value='stale-model']")
    assert has_element?(view, "#extraction-model-select option[value='fresh-model']")
  end

  @tag timeout: 10_000
  test "reopening over an in-flight fetch drops the earlier one", %{conn: conn, bypass: bypass} do
    hold_models_request(bypass, [["stale-model"], ["fresh-model"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, handler}, 5_000
    held = async_task_pid(view)
    held_ref = Process.monitor(held)

    # The trigger stays on the page behind the modal, so a second click starts a
    # replacement fetch while the first is still waiting on the server.
    view |> element("#show-reprocess") |> render_click()
    assert_receive {:DOWN, ^held_ref, :process, ^held, _reason}, 5_000
    assert_receive {:models_responded, 2}, 5_000
    render_async(view)

    assert has_element?(view, "#extraction-model-select option[value='fresh-model']")

    send(handler, :release)
    refute has_element?(view, "#extraction-model-select option[value='stale-model']")
  end

  @tag timeout: 10_000
  test "a retry that arrives after the modal closed asks for nothing", %{
    conn: conn,
    bypass: bypass
  } do
    hold_models_request(bypass, [["vision"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, handler}, 5_000

    view |> element("#reprocess-cancel") |> render_click()
    await_no_async(view)

    # A Retry click the client sent before it saw the modal close.
    render_click(view, "retry_reprocess_models")
    assert {:ok, []} = Channel.async_pids(view.pid)
    refute_receive {:models_responded, 2}, 200
    refute has_element?(view, "#reprocess-modal")

    send(handler, :release)
  end

  test "a model list is only applied to the open modal that asked for it" do
    socket = models_socket(show_reprocess_modal: true, models_request_id: 7)

    assert {:noreply, applied} =
             ReprocessModal.handle_async(:fetch_models, {:ok, {7, {:ok, ["vision"]}}}, socket)

    assert applied.assigns.available_models == ["vision"]
    refute applied.assigns.models_loading

    # A result that outran the close: the task was cancelled, so LiveView has no
    # newer ref to prune it against and it lands here regardless.
    closed = models_socket(show_reprocess_modal: false, models_request_id: 7)

    assert {:noreply, ^closed} =
             ReprocessModal.handle_async(:fetch_models, {:ok, {7, {:ok, ["vision"]}}}, closed)

    # Belt and braces for a future second `start_async` on this name.
    superseded = models_socket(show_reprocess_modal: true, models_request_id: 8)

    assert {:noreply, ^superseded} =
             ReprocessModal.handle_async(:fetch_models, {:ok, {7, {:ok, ["vision"]}}}, superseded)
  end

  defp models_socket(overrides) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          show_reprocess_modal: true,
          models_request_id: 1,
          models_loading: true,
          model_fetch_error: nil,
          available_models: [],
          extraction_model: "vision",
          translation_model: "translation",
          reprocess_form: nil
        },
        Map.new(overrides)
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  test "a failed model fetch can be retried from the modal", %{conn: conn, bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
        1 ->
          Plug.Conn.resp(conn, 401, "unauthorized")

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "vision"}]}))
      end
    end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    render_async(view)

    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-model-retry")
    assert has_element?(view, "#reprocess-submit-btn[disabled]")

    view |> element("#reprocess-model-retry") |> render_click()
    render_async(view)

    refute has_element?(view, "#reprocess-model-error")
    refute has_element?(view, "#extraction-model-select[disabled]")
    assert has_element?(view, "#extraction-model-select option[value='vision']")
    assert has_element?(view, "#translation-model-select option[value='vision']")

    view
    |> form("#reprocess-form", extraction_model: "vision", translation_model: "vision")
    |> render_change()

    refute has_element?(view, "#reprocess-submit-btn[disabled]")
  end
end
