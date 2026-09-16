defmodule DoctransWeb.ThemeScriptTest do
  use DoctransWeb.ConnCase, async: true

  # Regression guard for U10. Theme initialization used to be an inline
  # `<script>` in the root layout, which the router's own
  # `script-src 'self'` refuses, so nothing applied the saved theme and the
  # toggle did nothing. The behavior itself -- localStorage, the `storage`
  # event, the paint timing -- is browser-side and this repo has no JavaScript
  # test harness, so what is pinned here is the wiring that has to hold for
  # that behavior to be reachable at all: no inline script on the page, the
  # policy that forbids one still sent, and the bundle that replaced it both
  # referenced by the layout and produced by the build.

  @theme_source "assets/js/theme.js"

  describe "the rendered page" do
    setup %{conn: conn} do
      conn = get(conn, ~p"/")

      %{conn: conn, document: conn |> html_response(200) |> LazyHTML.from_document()}
    end

    test "carries no inline script", %{document: document} do
      scripts = LazyHTML.query(document, "script")
      sourced = LazyHTML.query(document, "script[src]")

      # Every script element must load from a URL, and carry no body of its
      # own. Either kind of inline script is refused by the CSP below, so it
      # would be dead code shipped on every response.
      assert LazyHTML.attribute(scripts, "src") != []
      assert Enum.count(scripts) == Enum.count(sourced)
      assert scripts |> LazyHTML.text() |> String.trim() == ""
    end

    test "loads the theme bundle without deferring it", %{document: document} do
      theme = LazyHTML.query(document, ~s(script[src^="/assets/js/theme.js"]))

      assert LazyHTML.attribute(theme, "src") != []
      # `defer` or `async` would move execution past the first paint, which is
      # the whole reason this is a separate bundle from the deferred app one.
      assert LazyHTML.attribute(theme, "defer") == []
      assert LazyHTML.attribute(theme, "async") == []
      # Tracked like every other bundle, so a stale asset still forces a reload.
      assert LazyHTML.attribute(theme, "phx-track-static") == [""]
    end

    test "loads the theme bundle before the app bundle", %{document: document} do
      srcs =
        document
        |> LazyHTML.query("script[src]")
        |> LazyHTML.attribute("src")

      theme = Enum.find_index(srcs, &String.starts_with?(&1, "/assets/js/theme.js"))
      app = Enum.find_index(srcs, &String.starts_with?(&1, "/assets/js/app.js"))

      assert is_integer(theme) and is_integer(app)
      assert theme < app
    end

    test "still forbids inline script in the content security policy", %{conn: conn} do
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "script-src 'self'"
      refute policy =~ "unsafe-inline"
      refute policy =~ "nonce-"
    end
  end

  describe "the theme bundle" do
    test "is an esbuild entry point, so the layout's reference resolves to a built file" do
      args = Application.fetch_env!(:esbuild, :doctrans)[:args]

      assert "js/theme.js" in args
      # Both entries share `--outdir`, which is what puts the output at the
      # `/assets/js/theme.js` the layout asks for.
      assert "--outdir=../priv/static/assets/js" in args
    end

    test "implements the three behaviors the layout no longer carries inline" do
      source = File.read!(@theme_source)

      # Selection, reload persistence, and cross-tab updates, in that order.
      assert source =~ "phx:set-theme"
      assert source =~ "phx:theme"
      assert source =~ ~s(addEventListener("storage")
      # "System" is stored as the absence of the key, which is what lets the
      # daisyUI themes fall through to `prefers-color-scheme`.
      assert source =~ "removeItem"
      assert source =~ ~s(removeAttribute("data-theme")
    end

    test "imports nothing, so it stays a small render-blocking request" do
      refute File.read!(@theme_source) =~ ~r/^\s*import\s/m
    end
  end
end
