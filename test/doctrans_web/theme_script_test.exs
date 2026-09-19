defmodule DoctransWeb.ThemeScriptTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

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
  @sync_source Path.expand("../../assets/js/theme_sync.js", __DIR__)
  @app_source Path.expand("../../assets/js/app.js", __DIR__)

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
      assert code =~ "dataset?.phxTheme"

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

      # And it is never written as a value. Asserting only that `removeItem`
      # appears somewhere leaves it possible to store the string as well, or
      # instead, with the removal stranded in a branch nothing reaches -- at
      # which point "system" freezes at whatever the preference was that day
      # and every assertion above still passes.
      refute code =~ ~r/setItem\([^)]*SYSTEM/
      refute code =~ ~r/setItem\(\s*STORAGE_KEY\s*,\s*["']system["']/
    end

    test "applies only the themes that exist, and survives storage it cannot use" do
      code = theme_code()

      # Review found both of these by dispatching the event by hand. An event
      # from a node with no `data-phx-theme` arrived as `undefined` and was
      # written straight through to `data-theme` and to storage, where it stuck
      # across reloads: it matches no theme, it suppresses
      # `prefers-color-scheme` because the attribute is present, and it leaves
      # every button unpressed. Dispatching on `window` threw outright.
      # Matched loosely: what has to hold is that an allow-list exists and is
      # consulted, not that it is spelled with `includes`.
      assert code =~ ~r/THEMES\s*=\s*\[/
      assert code =~ ~r/THEMES\.(?:includes|indexOf)\(/
      assert code =~ "event.target?.dataset?.phxTheme"

      # Storage throws rather than returning null when a browser is set to deny
      # site data. Unhandled, it would abort this file before the listeners
      # below it are registered, which is the dead toggle U10 set out to fix.
      assert code =~ ~r/try\s*\{/
      assert code =~ ~r/catch\s*\{/
    end

    test "imports only the toggle sync, so it stays a small render-blocking request" do
      imports =
        Regex.scan(~r/^\s*import\s+.*?from\s+"([^"]+)"/m, theme_code(), capture: :all_but_first)

      # esbuild copies an import into every entry point that pulls it in, so a
      # dependency here is paid for twice and lands in front of the first
      # paint. `theme_sync` is a dozen lines; anything else wants a reason.
      assert List.flatten(imports) == ["./theme_sync"]
      refute theme_code() =~ ~r/\brequire\(/
    end

    test "comments only whole lines, which is what lets the assertions above read code" do
      # `theme_code/0` strips whole-line `//` comments and nothing else, so two
      # kinds of comment could still satisfy every assertion above with prose
      # while the code behind them was deleted -- which is exactly how the first
      # cut of this file passed against a bundle with its listeners removed.

      # A block comment evades the stripper entirely.
      refute File.read!(@theme_source) =~ "/*"

      # A trailing comment survives it. `://` is allowed through so a URL in a
      # string literal does not read as one.
      refute theme_code() =~ ~r{(?<!:)//}
    end
  end

  describe "the theme toggle" do
    test "is reachable from every page", %{conn: conn} do
      # U12. The listener U10 restored is useless without a control that
      # dispatches to it, and the toggle was rendered by no template at all.
      document = document_fixture()

      for path <- [~p"/", ~p"/search", ~p"/documents/#{document.id}"] do
        group =
          conn
          |> get(path)
          |> html_response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query("#theme-toggle")

        assert LazyHTML.attribute(group, "phx-hook") == ["ThemeToggle"],
               "no theme toggle on #{path}"

        # Named, so the three unlabelled icon buttons are not announced as a
        # bare group of toggles.
        assert LazyHTML.attribute(group, "role") == ["group"]
        assert [label] = LazyHTML.attribute(group, "aria-label")
        assert label != ""
      end
    end

    test "states which theme is selected, rather than only drawing it", %{conn: conn} do
      # The selected option is otherwise shown only by a CSS-positioned pill,
      # which assistive technology cannot see. The server renders the
      # "system" default and the hook corrects it once a stored choice is
      # known; what matters here is that the attribute exists to be corrected.
      buttons =
        conn
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#theme-toggle [data-phx-theme]")

      assert LazyHTML.attribute(buttons, "data-phx-theme") == ~w(system light dark)
      assert LazyHTML.attribute(buttons, "aria-pressed") == ~w(true false false)
    end

    test "the pressed state is written without waiting for a socket" do
      # The placeholder above is corrected by `theme.js`, which has no
      # dependency on LiveView. Leaving it to the hook instead would leave the
      # buttons announcing "system" for the whole join -- and for good on a
      # connection where the socket never opens -- while the pill drew the
      # real choice.
      theme = theme_code()

      assert theme =~ "syncThemeToggles"
      assert theme =~ ~s|addEventListener("DOMContentLoaded", syncThemeToggles)|

      # And the writer itself does the writing.
      assert File.read!(@sync_source) =~ ~s|setAttribute("aria-pressed"|
    end

    test "the hook restores the pressed state after a patch re-renders the group" do
      # This is all the hook is for: a server patch rebuilds the buttons from a
      # template that does not know the theme, so it restores the placeholder.
      app = File.read!(@app_source)

      assert app =~ "ThemeToggle: {"
      assert app =~ ~r/updated\(\)\s*\{\s*syncThemeToggles\(\)/

      # Shared with `theme.js` rather than reimplemented, so the two cannot
      # disagree about what "pressed" means.
      assert app =~ ~s|from "./theme_sync"|
    end

    test "a stored value naming no theme is corrected rather than ignored" do
      # The version U10 replaced could write `data-theme="undefined"` and leave
      # it in storage. Rejecting it on read is not enough on its own: an
      # early return would keep the bad entry forever, healing only if the
      # reader happened to click. Coercing it to "system" clears the key.
      code = theme_code()

      assert code =~ ~r/THEMES\.(?:includes|indexOf)\([^)]*\)\s*\?/

      for call <- ["readTheme()", "event.newValue", "event.target?.dataset?.phxTheme"] do
        assert code =~ "asTheme(#{call})",
               "#{call} reaches setTheme without being coerced to a real theme"
      end
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
