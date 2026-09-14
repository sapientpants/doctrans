defmodule DoctransWeb.LocaleTest do
  use DoctransWeb.ConnCase, async: true

  # End-to-end coverage of locale resolution: the plug resolves it, the session
  # carries it, the root layout announces it, and the LiveView mount speaks it.
  # The Gettext locale is per-process, so nothing here leaks across async tests.

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
      assert get_session(conn, Locale.explicit_session_key()) == false
    end

    test "a reload over the same session cookie stays German", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/")
      reloaded = conn |> recycle() |> get(~p"/search")

      assert html_lang(html_response(reloaded, 200)) == ["de"]
      assert get_session(reloaded, Locale.session_key()) == "de"

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "h1", "Suche")
    end

    test "an unsupported browser language falls back to English", %{conn: conn} do
      conn = conn |> accept_language("ja-JP,ja;q=0.9") |> get(~p"/")

      assert html_lang(html_response(conn, 200)) == ["en"]
      assert text(html_response(conn, 200), "#documents-empty h3") =~ "No documents yet"
    end
  end

  describe "explicit lang parameter" do
    test "it is honoured, announced, and persisted as explicit", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      html = html_response(conn, 200)

      assert html_lang(html) == ["fr"]
      assert text(html, "#documents-empty h3") =~ "Aucun document"
      assert get_session(conn, Locale.session_key()) == "fr"
      assert get_session(conn, Locale.explicit_session_key()) == true
    end

    test "it outlives a later request that carries no parameter", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      later = conn |> recycle() |> get(~p"/search")

      assert html_lang(html_response(later, 200)) == ["fr"]
      assert get_session(later, Locale.session_key()) == "fr"

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "h1", "Recherche")
      refute has_element?(view, "h1", "Suche")
    end

    test "the connected mount speaks the chosen language", %{conn: conn} do
      {:ok, view, _html} = live(accept_language(conn, @german), ~p"/search?lang=fr")

      assert has_element?(view, "h1", "Recherche")
    end
  end

  describe "unsupported lang parameter" do
    test "a German browser hitting a bad link still gets German", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=zz")

      assert html_lang(html_response(conn, 200)) == ["de"]
      assert get_session(conn, Locale.session_key()) == "de"
    end

    test "it cannot reset a stored explicit choice", %{conn: conn} do
      conn = conn |> accept_language(@german) |> get(~p"/?lang=fr")
      conn = conn |> recycle() |> get(~p"/?lang=zz")

      assert html_lang(html_response(conn, 200)) == ["fr"]
      assert get_session(conn, Locale.session_key()) == "fr"
      assert get_session(conn, Locale.explicit_session_key()) == true

      {:ok, view, _html} = live(recycle(conn), ~p"/search")
      assert has_element?(view, "h1", "Recherche")
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
  end

  test "live navigation between LiveViews keeps the locale", %{conn: conn} do
    {:ok, view, _html} = live(accept_language(conn, @german), ~p"/search")
    assert has_element?(view, "h1", "Suche")

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
