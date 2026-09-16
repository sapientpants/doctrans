defmodule DoctransWeb.ThemeScriptTest do
  use DoctransWeb.ConnCase, async: true

  # Regression guard for U10. Theme initialization used to be an inline
  # `<script>` in the root layout, which the router's own `script-src 'self'`
  # refuses, so nothing applied the saved theme and the toggle did nothing. The
  # behavior itself -- localStorage, the `storage` event, the paint timing -- is
  # browser-side and this repo has no JavaScript test harness, so what is pinned
  # here is the wiring that has to hold for that behavior to be reachable at
  # all: no inline script on the page, the policy that forbids one still sent,
  # the load order the before-first-paint argument depends on, and a bundle that
  # still contains each of the three behaviors it took over.

  @theme_source Path.expand("../../assets/js/theme.js", __DIR__)

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

    test "carries no inline script on the other routes either", %{conn: conn} do
      # The root layout wraps every page, but only `/` is exercised above.
      scripts =
        conn
        |> get(~p"/search")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("script")

      assert LazyHTML.attribute(scripts, "src") != []
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

    test "keeps deferring the app bundle", %{document: document} do
      # The case for a second entry point is that this one is deferred and so
      # runs too late to set a theme. Undeferring it would dissolve that case
      # -- and block the parser on 300kb -- so the split must be revisited, not
      # silently left in place.
      app = LazyHTML.query(document, ~s(script[src^="/assets/js/app.js"]))

      assert LazyHTML.attribute(app, "defer") == [""]
    end

    test "loads the theme bundle ahead of the stylesheet and the app bundle", %{
      document: document
    } do
      # A parser-inserted blocking script waits on any stylesheet that precedes
      # it, so moving this one below the `<link>` would serialize it behind the
      # CSS and put `data-theme` on the far side of the paint it exists to
      # precede. Order is read from the head as authored.
      order =
        document
        |> LazyHTML.query("head script[src], head link[rel=stylesheet]")
        |> Enum.map(fn node ->
          LazyHTML.attribute(node, "src") ++ LazyHTML.attribute(node, "href")
        end)
        |> List.flatten()

      theme = index_of(order, "/assets/js/theme.js")
      stylesheet = index_of(order, "/assets/css/app.css")
      app = index_of(order, "/assets/js/app.js")

      assert is_integer(theme) and is_integer(stylesheet) and is_integer(app)
      assert theme < stylesheet
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
    test "is an esbuild entry point, so the layout's reference names a file the build emits" do
      args = Application.fetch_env!(:esbuild, :doctrans)[:args]

      assert "js/theme.js" in args
      # Both entries share `--outdir`, which is what puts the output at the
      # `/assets/js/theme.js` the layout asks for. Whether that build has
      # actually run is not checked here and cannot be: `priv/static/assets` is
      # gitignored and CI never builds assets. See Q08 in PLAN.md.
      assert "--outdir=../priv/static/assets/js" in args
    end

    test "implements the three behaviors the layout no longer carries inline" do
      code = theme_code()

      # Selection: the event `Layouts.theme_toggle/1` dispatches from phx-click.
      assert code =~ ~s|addEventListener("phx:set-theme"|
      assert code =~ "dataset.phxTheme"

      # Reload persistence: read the stored choice and apply it, but only over
      # an element that has no theme already.
      assert code =~ ~s|hasAttribute("data-theme")|
      assert code =~ "getItem(STORAGE_KEY)"
      assert code =~ ~s|setAttribute("data-theme"|
      assert code =~ "setItem(STORAGE_KEY"

      # Cross-tab updates.
      assert code =~ ~s|addEventListener("storage"|

      # "System" is stored as the absence of the key, which is what lets the
      # daisyUI themes fall through to `prefers-color-scheme` instead of
      # freezing at the preference in force when the choice was made.
      assert code =~ "removeItem(STORAGE_KEY)"
      assert code =~ ~s|removeAttribute("data-theme")|
    end

    test "imports nothing, so it stays a small render-blocking request" do
      refute theme_code() =~ ~r/\b(?:import|require)\b/
    end

    test "comments only whole lines, which is what lets the assertions above read code" do
      # `theme_code/0` strips whole-line comments. A trailing one could satisfy
      # every assertion above with prose while the code behind it was deleted,
      # which is exactly how the first cut of this file passed against a bundle
      # with its listeners removed.
      refute theme_code() =~ "//"
    end
  end

  # The file's own header names the events and storage key it handles, so the
  # assertions have to run against code rather than the whole source.
  defp theme_code do
    @theme_source
    |> File.read!()
    |> String.replace(~r{^\s*//.*$}m, "")
  end

  defp index_of(list, prefix), do: Enum.find_index(list, &String.starts_with?(&1, prefix))
end
