defmodule DoctransWeb.LocaleTest do
  use DoctransWeb.ConnCase, async: false

  # End-to-end coverage of locale resolution: the plug resolves it, the session
  # carries it, the root layout announces it, and the LiveView mount speaks it.
  # Locale is process-local, but connected dashboard mounts subscribe to global PubSub.

  alias DoctransWeb.Locale

  # A German browser that also accepts English, which is what made the original
  # defect invisible: the UI silently fell back to the English branch.
  @german "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7"

  describe "browser language detection" do
    test "the dead render is German for a German browser", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/")
      html = html_response(conn, 200)

      assert html_lang(html) == ["de"]
      assert text(html, "#documents-empty h3") =~ "Noch keine Dokumente"
      refute text(html, "#documents-empty h3") =~ "No documents yet"
    end

    test "the connected mount is German for a German browser", %{conn: conn} do
      {:ok, view, _html} = live(accept_language(conn, @german), ~p"/")

      assert has_element?(view, "#documents-empty h3", "Noch keine Dokumente")
      refute has_element?(view, "#documents-empty h3", "No documents yet")
    end

    test "the detected locale is stored in the session for the mount that follows",
         %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/")

      assert get_session(conn, Locale.session_key()) == "de"
      # Detection is not a choice, so nothing is pinned.
      assert get_session(conn, Locale.choice_session_key()) == nil
    end

    test "navigating on from the same browser stays German", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/")
      later = conn |> recycle() |> get(~p"/search")

      assert html_lang(html_response(later, 200)) == ["de"]
      assert get_session(later, Locale.session_key()) == "de"

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "#search-title", "Suche")
    end

    test "a detected locale follows the browser rather than the cookie", %{conn: conn} do
      # The documented tradeoff: only an explicit choice is pinned. `recycle/2`
      # with no copied headers keeps the session cookie but drops the header.
      conn = conn |> accept_language(@german) |> get(~p"/")
      later = conn |> recycle([]) |> get(~p"/")

      assert html_lang(html_response(later, 200)) == ["en"]
      assert get_session(later, Locale.session_key()) == "en"
    end

    test "an unsupported browser language falls back to English", %{conn: conn} do
      conn = conn |> accept_language("ja-JP,ja;q=0.9") |> get(~p"/")

      assert html_lang(html_response(conn, 200)) == ["en"]
      assert text(html_response(conn, 200), "#documents-empty h3") =~ "No documents yet"
    end

    test "a Norwegian browser reaches the Norwegian translations", %{conn: conn} do
      # Browsers send `nb`/`nn`; the translations live under the macrolanguage `no`.
      conn = conn |> accept_language("nb-NO,nb;q=0.9,en;q=0.8") |> get(~p"/")

      assert html_lang(html_response(conn, 200)) == ["no"]
    end
  end

  describe "explicit lang parameter" do
    test "it is honoured, announced, and persisted as a choice", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      html = html_response(conn, 200)

      assert html_lang(html) == ["fr"]
      assert text(html, "#documents-empty h3") =~ "Aucun document"
      assert get_session(conn, Locale.session_key()) == "fr"
      assert get_session(conn, Locale.choice_session_key()) == "fr"
    end

    test "it outlives a later request that carries no parameter", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      later = conn |> recycle() |> get(~p"/search")

      assert html_lang(html_response(later, 200)) == ["fr"]
      assert get_session(later, Locale.session_key()) == "fr"

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "#search-title", "Recherche")
      refute has_element?(view, "#search-title", "Suche")
    end

    test "it rides the session cookie, not the browser header", %{conn: conn} do
      # Dropping every copied header leaves only the cookie to carry the choice.
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      later = conn |> recycle([]) |> get(~p"/search")

      assert html_lang(html_response(later, 200)) == ["fr"]
      assert get_session(later, Locale.choice_session_key()) == "fr"
    end

    test "the connected mount speaks the chosen language", %{conn: conn} do
      {:ok, view, _html} = live(accept_language(conn, @german), ~p"/search?lang=fr")

      assert has_element?(view, "#search-title", "Recherche")
    end
  end

  describe "lang=auto" do
    test "it hands the language back to the browser", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      assert get_session(conn, Locale.choice_session_key()) == "fr"

      reset = conn |> recycle() |> get(~p"/?lang=auto")

      assert html_lang(html_response(reset, 200)) == ["de"]
      assert get_session(reset, Locale.choice_session_key()) == nil

      {:ok, view, _html} = live(recycle(reset), ~p"/")
      assert has_element?(view, "#documents-empty h3", "Noch keine Dokumente")
    end
  end

  describe "unsupported lang parameter" do
    test "a German browser hitting a bad link still gets German", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=zz")

      assert html_lang(html_response(conn, 200)) == ["de"]
      assert get_session(conn, Locale.session_key()) == "de"
    end

    test "it cannot reset a stored choice", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      conn = conn |> recycle() |> get(~p"/?lang=zz")

      assert html_lang(html_response(conn, 200)) == ["fr"]
      assert get_session(conn, Locale.session_key()) == "fr"
      assert get_session(conn, Locale.choice_session_key()) == "fr"

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "#search-title", "Recherche")
    end
  end

  describe "defaults" do
    test "no header and no session renders English", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html_lang(html) == ["en"]
      assert html_lang(html) == [Locale.default()]
      assert text(html, "#documents-empty h3") =~ "No documents yet"

      {:ok, view, _html} = live(recycle(conn), ~p"/")
      assert has_element?(view, "#documents-empty h3", "No documents yet")
    end

    test "the root layout still announces a language with no locale assigned" do
      # The plug is last in the :browser pipeline, so `:locale` is always
      # assigned in practice; this pins the fallback for any renderer that is
      # not behind it.
      html = rendered_to_string(DoctransWeb.Layouts.root(%{inner_content: ""}))

      assert html_lang(html) == [Locale.default()]
    end
  end

  test "live navigation between LiveViews keeps the locale", %{conn: conn} do
    {:ok, view, _html} = live(accept_language(conn, @german), ~p"/search")
    assert has_element?(view, "#search-title", "Suche")

    # A live redirect remounts from the session token of the original connect,
    # without a new HTTP request, which is what browser live navigation does.
    {:ok, index_view, _html} = live_redirect(view, to: ~p"/")

    assert has_element?(index_view, "#documents-empty h3", "Noch keine Dokumente")
  end

  defp accept_language(conn, header), do: put_req_header(conn, "accept-language", header)

  defp html_lang(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.filter("html")
    |> LazyHTML.attribute("lang")
  end

  defp text(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end
end
