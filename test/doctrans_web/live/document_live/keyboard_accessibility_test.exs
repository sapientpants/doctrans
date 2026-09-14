defmodule DoctransWeb.DocumentLive.KeyboardAccessibilityTest do
  @moduledoc """
  Regression tests for the keyboard and screen-reader contract of the dialogs.

  What these can cover: the rendered markup contract and the server-side events
  behind it -- dialog roles, the name each dialog and each icon-only control
  resolves to, the association between a label and its control, the fact that the
  file input is still in the tab order rather than `display:none`, and that the
  Escape key really closes a dialog through a handled event.

  What these cannot cover: where the focus ring actually goes. `phx-hook`,
  the DialogFocus hook runs in the
  browser, and `Phoenix.LiveViewTest` has no DOM to move focus in. These tests
  therefore assert only that the page *declares* the focus management; that it
  works is a browser-level concern. The same goes for what a screen reader
  announces: we assert the names exist and resolve, not how they are read out.
  """
  use DoctransWeb.ConnCase, async: false

  alias DoctransWeb.DocumentLive.Components

  import Doctrans.Fixtures

  @moduletag :capture_log

  setup do
    previous_uploads = Application.fetch_env!(:doctrans, :uploads)
    previous_extractor = Application.fetch_env!(:doctrans, :pdf_extractor_module)
    directory = Path.join(System.tmp_dir!(), "keyboard-a11y-#{Uniq.UUID.uuid7()}")
    File.mkdir_p!(directory)

    Application.put_env(:doctrans, :uploads, upload_dir: directory, max_file_size: 100_000)
    Application.put_env(:doctrans, :pdf_extractor_module, Doctrans.UploadPathExtractorStub)

    on_exit(fn ->
      Application.put_env(:doctrans, :uploads, previous_uploads)
      Application.put_env(:doctrans, :pdf_extractor_module, previous_extractor)
      File.rm_rf!(directory)
    end)

    :ok
  end

  describe "the upload dialog announces itself as a dialog" do
    test "carries the dialog role and a name that resolves to a real element", %{conn: conn} do
      view = open_upload_modal(conn)

      assert has_element?(view, ~s{#upload-modal[role="dialog"][aria-modal="true"]})

      # A dangling `aria-labelledby` names the dialog nothing at all, so the
      # target has to exist and carry the heading text.
      title_id = attribute(view, "#upload-modal", "aria-labelledby")
      assert has_element?(view, "h3##{title_id}")
    end

    test "closes on Escape", %{conn: conn} do
      view = open_upload_modal(conn)

      view |> element("#upload-modal") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#upload-modal")
      # The dashboard is still there to return to.
      assert has_element?(view, "#upload-document-btn")
    end
  end

  describe "the upload dialog's file input is reachable by keyboard" do
    test "is clipped rather than display:none, and is named", %{conn: conn} do
      view = open_upload_modal(conn)

      # `hidden` is `display:none`: it takes the input out of the tab order *and*
      # out of the accessibility tree. The only other way to the file picker is a
      # `<label>`, which is not focusable, so this would leave no keyboard path to
      # choosing a file at all.
      refute has_element?(view, "#upload-modal input[type=file].hidden")
      assert has_element?(view, "#upload-modal input[type=file].sr-only")

      label_id = attribute(view, "#upload-modal input[type=file]", "aria-labelledby")
      assert has_element?(view, "##{label_id}")
    end

    test "points at the formats-and-limit hint while no file is picked", %{conn: conn} do
      view = open_upload_modal(conn)

      hint_id = attribute(view, "#upload-modal input[type=file]", "aria-describedby")
      assert has_element?(view, "##{hint_id}")

      # The hint lives in the empty state, so the description goes away with it.
      add_file(view, "report.pdf", pdf_content())

      refute has_element?(view, "#upload-modal input[type=file][aria-describedby]")
      refute has_element?(view, "##{hint_id}")
    end
  end

  describe "the upload dialog's labels are associated with their controls" do
    test "the documents label targets the file input's own id", %{conn: conn} do
      view = open_upload_modal(conn)

      input_id = attribute(view, "#upload-modal input[type=file]", "id")

      assert has_element?(view, ~s{#upload-files-label[for="#{input_id}"]})
    end

    test "the target-language label targets the select", %{conn: conn} do
      view = open_upload_modal(conn)

      assert has_element?(view, ~s{#upload-modal label[for="target-lang-select"]})
      assert has_element?(view, "#upload-modal select#target-lang-select")
    end
  end

  describe "the upload dialog's icon-only controls are named" do
    test "the close button has an accessible name", %{conn: conn} do
      view = open_upload_modal(conn)

      assert has_element?(view, "#upload-modal-close[aria-label]")
      # An icon-only control whose icon is also announced reads its name twice.
      assert has_element?(view, ~s{#upload-modal-close .hero-x-mark[aria-hidden="true"]})
    end

    test "the backdrop is a named control rather than unlabelled scenery", %{conn: conn} do
      view = open_upload_modal(conn)

      assert has_element?(
               view,
               ~s{#upload-modal button.modal-backdrop[aria-label][tabindex="-1"]}
             )
    end

    test "each entry's remove button names the file it removes", %{conn: conn} do
      view = open_upload_modal(conn)
      add_file(view, "report.pdf", pdf_content())
      add_file(view, "minutes.pdf", pdf_content())

      # "Remove" repeated once per row says nothing about which file goes.
      assert has_element?(
               view,
               ~s{#upload-modal button[phx-click="cancel_upload"][aria-label*="report.pdf"]}
             )

      assert has_element?(
               view,
               ~s{#upload-modal button[phx-click="cancel_upload"][aria-label*="minutes.pdf"]}
             )
    end
  end

  describe "the dashboard names its controls" do
    test "the document card's link and delete button name the document", %{conn: conn} do
      document = document_fixture(%{title: "Quarterly Report"})
      {:ok, view, _html} = live(conn, ~p"/")

      card = "#documents-#{document.id}"

      assert has_element?(view, ~s{#{card} a[aria-label*="Quarterly Report"]})

      assert has_element?(
               view,
               ~s{#{card} button[phx-click="delete_document"][aria-label*="Quarterly Report"]}
             )
    end

    test "the card's thumbnail is decorative rather than named again" do
      # Rendered directly: a card only grows an `<img>` once its first page has an
      # extracted image, and the card's own markup is what this pins down. The
      # link and the heading already carry the title, so alt text here repeats it.
      document = document_fixture(%{title: "Quarterly Report"})

      summary = %Doctrans.Documents.Summary{
        id: document.id,
        document: document,
        progress: 100.0,
        failed_pages: [],
        thumbnail_path: "documents/#{document.id}/pages/page_1.png"
      }

      card = &Components.document_card/1
      fragment = card |> render_component(summary: summary) |> LazyHTML.from_fragment()

      assert LazyHTML.query(fragment, "img") |> Enum.count() == 1
      assert LazyHTML.query(fragment, "img") |> LazyHTML.attribute("alt") == [""]
    end

    test "the search field and the sort trigger are named and focusable", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#dashboard-search-form[role="search"]})
      assert has_element?(view, ~s{label[for="dashboard-search-input"]})
      assert has_element?(view, "input#dashboard-search-input")

      # A bare `<label tabindex="0">` is announced as nothing; the trigger has to
      # say it is a button and say what it does.
      assert has_element?(
               view,
               ~s{.dropdown div[tabindex="0"][role="button"][aria-haspopup="true"][aria-label]}
             )

      # Menu entries default to `type="submit"` without this, which submits the
      # search form when activated by keyboard.
      assert has_element?(view, ~s{.dropdown-content button[type="button"][phx-click="sort"]})
    end
  end

  describe "the reprocess dialog" do
    setup :stub_model_list

    test "announces itself as a named dialog with a named close button", %{conn: conn} do
      view = open_reprocess_modal(conn)

      assert has_element?(view, ~s{#reprocess-modal[role="dialog"][aria-modal="true"]})

      title_id = attribute(view, "#reprocess-modal", "aria-labelledby")
      assert has_element?(view, "##{title_id}")

      assert has_element?(view, "#reprocess-close[aria-label]")
    end

    test "closes on Escape", %{conn: conn} do
      view = open_reprocess_modal(conn)

      view |> element("#reprocess-modal") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#reprocess-modal")
      assert has_element?(view, "#show-reprocess")
    end

    test "the buttons that open it say which scope they reprocess", %{conn: conn} do
      document = reprocessable_document()
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, "#show-reprocess[aria-label]")

      assert has_element?(
               view,
               ~s{button[phx-click="show_document_reprocess_modal"][aria-label]}
             )
    end
  end

  describe "both dialogs declare focus management" do
    setup context do
      if context[:stub_models], do: stub_model_list(context), else: :ok
    end

    # Declaration only. The DialogFocus hook runs in the browser -- LiveViewTest
    # has no DOM, so nothing here proves focus actually moved or came back. These
    # assertions exist so the declarations cannot be dropped silently; the
    # behaviour itself is verified with Puppeteer against a running server.
    #
    # `data-return-focus` is the load-bearing part. `JS.push_focus/0` pushes the
    # element the command is attached to -- the dialog -- not whatever was
    # focused before it opened, so popping focused a node that was being removed
    # and focus fell to the body. The trigger is named explicitly instead.
    test "the upload dialog traps focus and names where it returns", %{conn: conn} do
      view = open_upload_modal(conn)

      assert has_element?(view, ~s{#upload-modal[phx-hook="DialogFocus"]})
      assert has_element?(view, ~s{#upload-modal[data-return-focus="#upload-document-btn"]})
      assert has_element?(view, "#upload-document-btn")
      assert has_element?(view, ~s{#upload-modal[phx-window-keydown][phx-key="escape"]})
    end

    @tag :stub_models
    test "the reprocess dialog traps focus and names the trigger of its scope", %{conn: conn} do
      view = open_reprocess_modal(conn)

      assert has_element?(view, ~s{#reprocess-modal[phx-hook="DialogFocus"]})
      # The page-scope trigger, because that is the one this dialog was opened from.
      assert has_element?(view, ~s{#reprocess-modal[data-return-focus="#show-reprocess"]})
      assert has_element?(view, "#show-reprocess")
      assert has_element?(view, ~s{#reprocess-modal[phx-window-keydown][phx-key="escape"]})
    end
  end

  # The reprocess dialog asks the model endpoint as it opens; the answer is not
  # what these tests are about, so it is stubbed rather than left to fail.
  defp stub_model_list(_context) do
    previous = Application.fetch_env!(:doctrans, :openai)
    bypass = Bypass.open()

    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "vision"}]}))
    end)

    Application.put_env(
      :doctrans,
      :openai,
      Keyword.put(previous, :base_url, "http://localhost:#{bypass.port}")
    )

    on_exit(fn -> Application.put_env(:doctrans, :openai, previous) end)

    :ok
  end

  # Reads one attribute off a single matched element, so an assertion can follow
  # an `aria-*` reference to the element it points at instead of assuming its id.
  defp attribute(view, selector, name) do
    assert [value] =
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute(name)

    value
  end

  defp open_upload_modal(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#upload-document-btn") |> render_click()

    view
  end

  defp open_reprocess_modal(conn) do
    document = reprocessable_document()
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#show-reprocess") |> render_click()
    render_async(view)

    view
  end

  defp reprocessable_document do
    document = document_fixture(%{total_pages: 1, status: "completed"})
    completed_page_fixture(document)

    document
  end

  # One `file_input` per file: LiveViewTest's upload client is linked to the
  # channel of every entry it holds, so a multi-entry input loses its siblings.
  defp add_file(view, name, content) do
    upload =
      file_input(view, "#upload-form", :document, [
        %{name: name, content: content, type: "application/octet-stream"}
      ])

    render_upload(upload, name)
  end

  defp pdf_content, do: "%PDF-1.7\n" <> String.duplicate("x", 23)
end
