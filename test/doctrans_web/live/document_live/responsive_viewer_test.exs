defmodule DoctransWeb.DocumentLive.ResponsiveViewerTest do
  @moduledoc """
  The viewer below `lg` shows one panel at a time behind a tab switcher, and the
  chat becomes a dismissable overlay instead of a third in-flow column.

  Scope note: only the *server-rendered* half of that contract is testable here.
  Which panel a browser actually paints is decided by Tailwind breakpoints, so
  these tests assert the class tokens the markup ships (`hidden`/`flex`,
  `lg:flex`, `lg:w-1/2`) rather than a computed layout. Likewise, the chat's
  "keep following the answer only while the reader is already near the bottom"
  behaviour lives entirely in the `ChatScroll` hook in `assets/js/app.js` and is
  **not** exercised by this suite -- the tests below only pin that the hook is
  wired up and that its affordance exists in the markup for it to toggle.
  """

  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Repo

  describe "panel switcher below lg" do
    setup do
      %{document: viewer_document()}
    end

    test "opens on the translated panel", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, ~s{#view-tab-translated[aria-pressed="true"]})
      assert has_element?(view, ~s{#view-tab-original[aria-pressed="false"]})

      assert_selected(view, "#translated-panel")
      assert_unselected(view, "#original-panel")
    end

    test "selecting a tab swaps which panel is shown, in both directions", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      view |> element("#view-tab-original") |> render_click()

      assert has_element?(view, ~s{#view-tab-original[aria-pressed="true"]})
      assert has_element?(view, ~s{#view-tab-translated[aria-pressed="false"]})
      assert_selected(view, "#original-panel")
      assert_unselected(view, "#translated-panel")

      view |> element("#view-tab-translated") |> render_click()

      assert has_element?(view, ~s{#view-tab-translated[aria-pressed="true"]})
      assert has_element?(view, ~s{#view-tab-original[aria-pressed="false"]})
      assert_selected(view, "#translated-panel")
      assert_unselected(view, "#original-panel")
    end

    test "both panels keep lg:flex whichever tab is selected", %{
      conn: conn,
      document: document
    } do
      # The tab only decides what a narrow viewport shows. From `lg:` up both
      # panels are visible side by side, which only holds while each panel keeps
      # `lg:flex` to override its own `hidden`. Rendering just the selected panel
      # -- the obvious "simplification" -- would pass every aria-pressed
      # assertion above and silently delete the desktop split.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      for panel <- ~w(#original-panel #translated-panel) do
        assert has_element?(view, ~s{#{panel}[class~="lg:flex"]})
      end

      view |> element("#view-tab-original") |> render_click()

      for panel <- ~w(#original-panel #translated-panel) do
        assert has_element?(view, ~s{#{panel}[class~="lg:flex"]})
      end
    end

    test "the unselected panel stays in the DOM with its content", %{
      conn: conn,
      document: document
    } do
      # Hiding is a class, not a removal: the content of both panels stays on the
      # page so switching tabs is free and nothing downstream (chat context, the
      # page image, the zoom controls) depends on which tab is active.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      view |> element("#view-tab-original") |> render_click()

      assert has_element?(view, "#original-panel")
      assert has_element?(view, "#translated-panel")
      assert has_element?(view, "#translated-panel span", "Translated Content")
      assert has_element?(view, "#original-panel button[phx-click='zoom_in']")

      view |> element("#view-tab-translated") |> render_click()

      assert has_element?(view, "#original-panel")
      assert has_element?(view, "#translated-panel")
      assert has_element?(view, "#translated-panel span", "Translated Content")
      assert has_element?(view, "#original-panel button[phx-click='zoom_in']")
    end

    test "a forged tab value is ignored instead of crashing the view", %{
      conn: conn,
      document: document
    } do
      # The tab name arrives from the client, so every value that is not one of
      # the two known panels has to be dropped: the previous selection stands and
      # the LiveView stays up.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      for params <- [%{"tab" => "nonsense"}, %{"tab" => ""}, %{}] do
        render_click(view, "select_view_tab", params)

        assert view_tab(view) == :translated
        assert has_element?(view, ~s{#view-tab-translated[aria-pressed="true"]})
        assert_selected(view, "#translated-panel")
      end

      view |> element("#view-tab-original") |> render_click()

      for params <- [%{"tab" => "nonsense"}, %{}] do
        render_click(view, "select_view_tab", params)

        assert view_tab(view) == :original
        assert has_element?(view, ~s{#view-tab-original[aria-pressed="true"]})
        assert_selected(view, "#original-panel")
      end
    end

    test "the switcher is a named group that hides itself at lg", %{
      conn: conn,
      document: document
    } do
      # At `lg:` the choice it offers no longer exists, so the group goes away
      # rather than describing a switch that does nothing.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, ~s{#viewer-tabs[role="group"]})
      assert String.trim(attribute(view, "#viewer-tabs", "aria-label")) != ""
      assert has_element?(view, ~s{#viewer-tabs[class~="lg:hidden"]})

      # Each tab names the panel it governs, and that panel is on the page.
      for tab <- ~w(#view-tab-original #view-tab-translated) do
        panel = attribute(view, tab, "aria-controls")
        assert has_element?(view, "##{panel}")
      end

      assert attribute(view, "#view-tab-original", "aria-controls") == "original-panel"
      assert attribute(view, "#view-tab-translated", "aria-controls") == "translated-panel"
    end

    test "the translated tab is labelled like the panel it opens", %{
      conn: conn,
      document: document
    } do
      # With "Show Original" on, that panel shows the untranslated text, and a tab
      # still reading "Translated Content" would name the wrong thing.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert text_of(view, "#view-tab-translated") == "Translated Content"
      assert has_element?(view, "#translated-panel span", "Translated Content")

      view |> element("#translated-panel input[phx-click='toggle_original']") |> render_click()

      assert text_of(view, "#view-tab-translated") == "Original Content"
      assert has_element?(view, "#translated-panel span", "Original Content")

      view |> element("#translated-panel input[phx-click='toggle_original']") |> render_click()

      assert text_of(view, "#view-tab-translated") == "Translated Content"
    end

    test "opening the chat narrows both panels and closing restores them", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      for panel <- ~w(#original-panel #translated-panel) do
        assert has_element?(view, ~s{#{panel}[class~="lg:w-1/2"]})
      end

      view |> element("#toggle-chat") |> render_click()

      for panel <- ~w(#original-panel #translated-panel) do
        assert has_element?(view, ~s{#{panel}[class~="lg:w-2/5"]})
        refute has_element?(view, ~s{#{panel}[class~="lg:w-1/2"]})
      end

      view |> element("#toggle-chat") |> render_click()

      for panel <- ~w(#original-panel #translated-panel) do
        assert has_element?(view, ~s{#{panel}[class~="lg:w-1/2"]})
        refute has_element?(view, ~s{#{panel}[class~="lg:w-2/5"]})
      end
    end

    test "the viewer contributes exactly one main landmark", %{conn: conn, document: document} do
      # The layout already renders the page's `<main>`; a second one nested inside
      # it gives a screen reader two "main content" landmarks to choose between.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert main_count(view) == 1

      view |> element("#toggle-chat") |> render_click()

      assert main_count(view) == 1
    end
  end

  describe "chat overlay below lg" do
    setup do
      %{document: create_completed_document_with_embeddings()}
    end

    test "the open chat is a named aside that overlays narrow viewports and docks at lg", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      assert has_element?(view, "aside#chat-panel")
      assert String.trim(attribute(view, "#chat-panel", "aria-label")) != ""

      # Overlay half: pinned over the page on a narrow viewport.
      assert has_element?(view, ~s{#chat-panel[class~="fixed"]})

      # Sidebar half: back in flow as a fixed-width column from `lg:` up. Losing
      # either half is a broken layout at one size while the other still looks fine.
      assert has_element?(view, ~s{#chat-panel[class~="lg:static"]})
      assert has_element?(view, ~s{#chat-panel[class~="lg:w-80"]})
    end

    test "the backdrop is present only while the chat is open and dismisses it", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      refute has_element?(view, "#chat-panel")
      refute has_element?(view, "#chat-backdrop")

      view |> element("#toggle-chat") |> render_click()

      assert has_element?(view, "#chat-backdrop")
      # The backdrop exists only for the overlay, so it disappears where the chat
      # sits in flow and nothing is covered.
      assert has_element?(view, ~s{#chat-backdrop[class~="lg:hidden"]})
      assert has_element?(view, ~s{#chat-backdrop[aria-hidden="true"]})

      view |> element("#chat-backdrop") |> render_click()

      refute has_element?(view, "#chat-panel")
      refute has_element?(view, "#chat-backdrop")
      assert has_element?(view, ~s{#toggle-chat[aria-expanded="false"]})
    end

    test "the chat panel is not a modal dialog", %{conn: conn, document: document} do
      # Deliberate, not an oversight: the `ChatInput` hook declines to take focus
      # while a `role="dialog" aria-modal="true"` element is open, so promoting the
      # overlay to a modal dialog would quietly stop the chat input from being
      # refocused after every answer. It is a labelled `<aside>` landmark instead.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      assert has_element?(view, "aside#chat-panel")
      refute has_element?(view, ~s{#chat-panel[role="dialog"]})
      refute has_element?(view, "#chat-panel[aria-modal]")
    end

    test "the scroll container is wired to the ChatScroll hook and ships its jump affordance",
         %{conn: conn, document: document} do
      # Attribute-level only. Whether the view follows a streaming answer, and when
      # it reveals the button below, is decided by the `ChatScroll` hook in the
      # browser; this test cannot and does not verify that behaviour -- it pins the
      # contract the hook depends on: the hook name, a wrapper LiveView will not
      # patch (`phx-update="ignore"`, since visibility is pure client state), the
      # `hidden` starting state, and the button the hook reveals.
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      assert has_element?(view, ~s{#chat-scroll[phx-hook="ChatScroll"]})
      assert has_element?(view, ~s{#chat-new-messages[phx-update="ignore"]})
      assert has_element?(view, ~s{#chat-new-messages[class~="hidden"]})
      assert has_element?(view, "#chat-new-messages button#chat-jump-to-latest")
    end
  end

  defp viewer_document do
    document = document_fixture(%{status: "completed", total_pages: 1})
    completed_page_fixture(document)
    Documents.get_document_with_pages!(document.id)
  end

  # Mirrors the chat setup in `show_chat_test.exs`: a completed page carrying an
  # embedding, so the chat opens with a usable context.
  defp create_completed_document_with_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de",
        status: "completed",
        total_pages: 1
      })

    Repo.insert!(%Doctrans.Documents.Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: 1,
      image_path: "documents/#{document.id}/pages/page_1.png",
      original_markdown: "Test content for chat",
      translated_markdown: "Testinhalt für Chat",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    })

    document
  end

  # A panel the narrow viewport shows: laid out (`flex`), not hidden.
  defp assert_selected(view, panel) do
    assert has_element?(view, ~s{#{panel}[class~="flex"]})
    refute has_element?(view, ~s{#{panel}[class~="hidden"]})
  end

  # A panel the narrow viewport hides. It is still rendered -- only `hidden`.
  defp assert_unselected(view, panel) do
    assert has_element?(view, panel)
    assert has_element?(view, ~s{#{panel}[class~="hidden"]})
    refute has_element?(view, ~s{#{panel}[class~="flex"]})
  end

  defp view_tab(view), do: :sys.get_state(view.pid).socket.assigns.view_tab

  defp main_count(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("main")
    |> Enum.count()
  end

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  # Reads one attribute off a single matched element, so an assertion can follow
  # an `aria-*` reference to the element it names instead of assuming its id.
  defp attribute(view, selector, name) do
    assert [value] =
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute(name)

    value
  end
end
