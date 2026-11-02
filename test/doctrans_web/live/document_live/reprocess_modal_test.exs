defmodule DoctransWeb.DocumentLive.ReprocessModalTest do
  # The model list the dialog fetches is `OpenAIMock`'s answer. The fetch runs
  # in a task the LiveView under test spawned, so it carries this test's stubs
  # and nothing here touches the application env or the circuit breakers (#193).
  # The one test that does, the embedding-model filter, lives in
  # `ReprocessModalEmbeddingFilterTest`.
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  alias Doctrans.{Config, Documents}
  alias Doctrans.Documents.{Layout, Topics}
  alias Doctrans.Processing.{OpenAIMock, Run}
  alias DoctransWeb.DocumentLive.ReprocessModal
  alias DoctransWeb.ErrorMessages
  alias Phoenix.LiveView.Channel

  test "opening restores the page's recorded models and the page is reprocessed", %{conn: conn} do
    stub_models(["vision", "translation", "alternative"])

    document = document_fixture(%{total_pages: 1, status: "completed"})
    page = completed_page_fixture(document)
    {:ok, page} = Documents.update_page_extraction(page, %{extraction_model: "vision"})
    {:ok, page} = Documents.update_page_translation(page, %{translation_model: "translation"})
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

  test "pages without model history use configured defaults", %{conn: conn} do
    extraction = Config.OpenAI.vision_model()
    translation = Config.OpenAI.translation_model()
    stub_models(Enum.uniq([extraction, translation]))

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
      conn: conn
    } do
      stub_models(["available"])

      document = document_fixture(%{total_pages: 1, status: "completed"})
      page = completed_page_fixture(document)

      models =
        Map.put(
          %{extraction_model: "available", translation_model: "available"},
          @unavailable_field,
          "removed"
        )

      {:ok, page} = Documents.update_page_extraction(page, Map.take(models, [:extraction_model]))

      {:ok, _page} =
        Documents.update_page_translation(page, Map.take(models, [:translation_model]))

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

  test "model fetch failure leaves an error and disables submission", %{conn: conn} do
    Mox.stub(OpenAIMock, :list_models, fn -> {:error, {:http_error, [status: 401]}} end)

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    render_async(view)

    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-submit-btn[disabled]")
    refute has_element?(view, "#extraction-model-select[disabled]")
  end

  defp stub_models(models), do: Mox.stub(OpenAIMock, :list_models, fn -> {:ok, models} end)

  # Long enough that a fetch running inside the LiveView process would trip the
  # per-test timeout below instead of merely making the test slow, but under that
  # timeout so a failing test is not held in teardown by a still-blocked fetch.
  @held_request_timeout 8_000

  defp two_page_document do
    document = document_fixture(%{total_pages: 2, status: "completed"})
    completed_page_fixture(document)

    completed_page_fixture(document, %{
      page_number: 2,
      image_path: "documents/#{document.id}/pages/page_2.png"
    })

    document
  end

  # Answers `list_models/0` with `responses` in order, holding the first one
  # until the test releases it. The stub runs inside the fetch task, so the
  # `{:models_requested, pid}` it sends names that task: cancelling the fetch
  # kills it mid-hold, and the held answer is never produced.
  defp hold_models_request(responses) do
    test_pid = self()
    counter = call_counter()

    Mox.stub(OpenAIMock, :list_models, fn ->
      attempt = counter.()

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
      {:ok, models}
    end)
  end

  # Fails the first `list_models/0` call and serves a list to every one after
  # it, so a test can drive the error alert and then its Retry control.
  defp fail_then_serve_models do
    counter = call_counter()

    Mox.stub(OpenAIMock, :list_models, fn ->
      case counter.() do
        1 -> {:error, {:http_error, [status: 401]}}
        _ -> {:ok, ["vision"]}
      end
    end)
  end

  # Numbers the calls a stub receives, across the tasks they run in.
  defp call_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end
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
  test "an unanswered model fetch leaves the rest of the LiveView responsive", %{conn: conn} do
    hold_models_request([["vision"]])

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
    Topics.broadcast_document_updated(retitled)
    assert has_element?(view, "header h1", "Still serving updates")

    {:ok, page_two} =
      document.id
      |> Documents.get_page_by_number(2)
      |> Documents.update_page_extraction(%{
        extraction_status: "completed",
        original_markdown: "# Progress arrived"
      })

    Topics.broadcast_page_updated(page_two)
    render_click(view, "toggle_original")
    assert has_element?(view, ".markdown h1", "Progress arrived")

    view |> element("header button[phx-click='toggle_chat']") |> render_click()
    assert has_element?(view, "#chat-messages")

    assert has_element?(view, "#reprocess-modal")
    view |> element("#reprocess-cancel") |> render_click()
    refute has_element?(view, "#reprocess-modal")

    send(handler, :release)
  end

  @tag timeout: 10_000
  test "closing the modal drops its fetch, and reopening asks again", %{conn: conn} do
    hold_models_request([["stale-model"], ["fresh-model"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, _handler}, 5_000
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
    refute log =~ "Model fetch crashed"
    refute has_element?(view, "#reprocess-modal")

    # The reopened modal asks again; only that newer answer may render.
    view |> element("#show-reprocess") |> render_click()
    render_async(view)
    assert_receive {:models_responded, 2}, 5_000
    assert has_element?(view, "#extraction-model-select option[value='fresh-model']")
    refute has_element?(view, "#reprocess-model-error")

    # No assertion about the abandoned answer belongs here. Cancelling the task
    # kills the process the held stub is waiting in, so the stale list is never
    # produced and no implementation could render it. The proof that cancelling
    # works is the `{:DOWN, ...}` above; the proof that a stale payload would be
    # rejected on arrival is the `handle_async/3` unit test against a closed
    # modal.
  end

  @tag timeout: 10_000
  test "reopening over an in-flight fetch drops the earlier one", %{conn: conn} do
    hold_models_request([["stale-model"], ["fresh-model"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, _handler}, 5_000
    held = async_task_pid(view)
    held_ref = Process.monitor(held)

    # The trigger stays on the page behind the modal, so a second click starts a
    # replacement fetch while the first is still waiting on the server.
    view |> element("#show-reprocess") |> render_click()
    assert_receive {:DOWN, ^held_ref, :process, ^held, _reason}, 5_000
    assert_receive {:models_responded, 2}, 5_000
    render_async(view)

    assert has_element?(view, "#extraction-model-select option[value='fresh-model']")
  end

  @tag timeout: 10_000
  test "a retry that arrives after the modal closed asks for nothing", %{conn: conn} do
    hold_models_request([["vision"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, _handler}, 5_000

    view |> element("#reprocess-cancel") |> render_click()
    await_no_async(view)

    # A Retry click the client sent before it saw the modal close.
    render_click(view, "retry_reprocess_models")
    assert {:ok, []} = Channel.async_pids(view.pid)
    refute has_element?(view, "#reprocess-modal")
  end

  test "a model list is only applied to the open modal that asked for it" do
    socket = models_socket(show_reprocess_modal: true)

    assert {:noreply, applied} =
             ReprocessModal.handle_async(:fetch_models, {:ok, {:ok, ["vision"]}}, socket)

    assert applied.assigns.available_models == ["vision"]
    refute applied.assigns.models_loading

    # A result that outran the close: the task was cancelled, so LiveView has no
    # newer ref to prune it against and it lands here regardless.
    closed = models_socket(show_reprocess_modal: false)

    assert {:noreply, ^closed} =
             ReprocessModal.handle_async(:fetch_models, {:ok, {:ok, ["vision"]}}, closed)
  end

  test "a crashed fetch raises the error alert on the open modal" do
    socket = models_socket(show_reprocess_modal: true)

    {result, log} =
      with_log(fn ->
        ReprocessModal.handle_async(:fetch_models, {:exit, {%RuntimeError{}, []}}, socket)
      end)

    assert {:noreply, failed} = result
    assert failed.assigns.model_fetch_error == ErrorMessages.message(:models_unavailable)
    assert failed.assigns.available_models == []
    refute failed.assigns.models_loading
    assert log =~ "Model fetch crashed"
  end

  test "a crashed fetch that outran the close changes nothing" do
    closed = models_socket(show_reprocess_modal: false)

    {result, _log} =
      with_log(fn ->
        ReprocessModal.handle_async(:fetch_models, {:exit, {%RuntimeError{}, []}}, closed)
      end)

    assert {:noreply, ^closed} = result
  end

  test "a cancelled fetch is neither logged nor surfaced" do
    socket = models_socket(show_reprocess_modal: false)

    {result, log} =
      with_log(fn ->
        ReprocessModal.handle_async(:fetch_models, {:exit, {:shutdown, :cancel}}, socket)
      end)

    assert {:noreply, ^socket} = result
    refute log =~ "Model fetch"
  end

  test "the application crash warning classifies the exception without its sensitive details" do
    for secret <- ["sk-short-sentinel", "sk-" <> String.duplicate("s3cret", 100)] do
      frame = {Req, :request, [%{headers: %{"authorization" => ["Bearer " <> secret]}}], []}

      reason =
        {%RuntimeError{message: secret <> " https://user:password@host/?key=private"}, [frame]}

      {_result, log} =
        with_log(fn ->
          ReprocessModal.handle_async(
            :fetch_models,
            {:exit, reason},
            models_socket(show_reprocess_modal: true)
          )
        end)

      assert log =~ "Model fetch crashed: RuntimeError"

      for sensitive <- ["sk-", "s3cret", "password", "private", "authorization"] do
        refute log =~ sensitive
      end
    end
  end

  test "an ordinary fetch failure says what went wrong" do
    socket = models_socket(show_reprocess_modal: true)

    {result, log} =
      with_log(fn ->
        ReprocessModal.handle_async(:fetch_models, {:ok, {:error, :timeout}}, socket)
      end)

    assert {:noreply, failed} = result
    assert failed.assigns.model_fetch_error == ErrorMessages.message(:models_unavailable)
    refute failed.assigns.models_loading
    assert log =~ "Model fetch failed"
    assert log =~ ":timeout"
  end

  defp models_socket(overrides) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          show_reprocess_modal: true,
          models_loading: true,
          model_fetch_error: nil,
          available_models: [],
          reprocess_form:
            Phoenix.Component.to_form(%{
              "extraction_model" => "vision",
              "translation_model" => "translation"
            })
        },
        Map.new(overrides)
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  test "a failed model fetch can be retried from the modal", %{conn: conn} do
    fail_then_serve_models()

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

  test "the document modal can retry a failed fetch too", %{conn: conn} do
    fail_then_serve_models()

    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)

    # The document-scope trigger is disabled unless the original upload is still
    # on disk.
    directory = Layout.document_dir(document.id)
    File.mkdir_p!(directory)
    File.write!(Run.source_path(document), "original pdf")
    on_exit(fn -> File.rm_rf(directory) end)

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-document-reprocess") |> render_click()
    render_async(view)

    assert has_element?(view, "#document-reprocess-form")
    assert has_element?(view, "#reprocess-model-retry")

    view |> element("#reprocess-model-retry") |> render_click()
    render_async(view)

    refute has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#extraction-model-select option[value='vision']")
  end

  # Clearing the error here would unmount the alert containing the button the
  # user just clicked, dropping focus to the body outside the dialog.
  @tag timeout: 10_000
  test "retrying keeps the alert mounted until the answer lands", %{conn: conn} do
    test_pid = self()
    counter = call_counter()

    Mox.stub(OpenAIMock, :list_models, fn ->
      case counter.() do
        1 ->
          {:error, {:http_error, [status: 401]}}

        _ ->
          send(test_pid, {:models_requested, self()})

          receive do
            :release -> :ok
          after
            @held_request_timeout -> :ok
          end

          {:ok, ["vision"]}
      end
    end)

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    render_async(view)
    assert has_element?(view, "#reprocess-model-retry")

    view |> element("#reprocess-model-retry") |> render_click()
    assert_receive {:models_requested, handler}, 5_000

    # Mid-retry: the alert is still there, and so is the button that started it.
    assert has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#reprocess-model-retry[disabled]")

    send(handler, :release)
    render_async(view)

    refute has_element?(view, "#reprocess-model-error")
    assert has_element?(view, "#extraction-model-select option[value='vision']")
  end

  # The button is hidden while a fetch runs, but the event is not: a client can
  # push it regardless, and every extra push is a real request on an endpoint
  # that is already failing.
  @tag timeout: 10_000
  test "retrying while a fetch is already in flight asks the server once", %{conn: conn} do
    hold_models_request([["vision"]])

    document = two_page_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    assert_receive {:models_requested, _handler}, 5_000

    held = async_task_pid(view)

    for _ <- 1..5, do: render_click(view, "retry_reprocess_models")

    # The original fetch was neither replaced nor joined by a second one.
    assert {:ok, [^held]} = Channel.async_pids(view.pid)
    refute_receive {:models_requested, _another}, 200
  end

  # A closed modal keeps no meaningful loading state. It is masked today because
  # every path that opens the modal refetches, so this pins the invariant rather
  # than a visible symptom: the first open path that reuses a cached list would
  # otherwise render a spinner with no Retry button to escape it.
  test "closing the modal clears its loading flag" do
    socket =
      models_socket(show_reprocess_modal: true, models_loading: true, reprocess_scope: :page)

    assert {:noreply, closed} = ReprocessModal.handle_event("hide_reprocess_modal", %{}, socket)

    refute closed.assigns.show_reprocess_modal
    refute closed.assigns.models_loading
  end

  test "a retry is refused while one is already running" do
    socket = models_socket(show_reprocess_modal: true, models_loading: true)

    assert {:noreply, ^socket} =
             ReprocessModal.handle_event("retry_reprocess_models", %{}, socket)
  end
end
