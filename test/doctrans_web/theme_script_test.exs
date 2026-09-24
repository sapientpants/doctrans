defmodule DoctransWeb.ThemeScriptTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  # Server tests cover CSP, asset serving and load order. The Node harness
  # executes the real theme modules and the hook registered by app.js.
  @theme_tests Path.expand("../js/theme_test.mjs", __DIR__)

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

    test "serves every asset it references", %{document: document} do
      # Until the gate built the bundles this could not be asserted at all:
      # `priv/static/assets` is gitignored and neither CI nor pre-commit ever ran
      # `mix assets.build`, so deleting `priv/static/assets/js/theme.js` left the
      # whole suite green while a reader got a 404 on a render-blocking script --
      # which stalls the parser rather than quietly doing nothing, the reason
      # theme initialization moved into a bundle of its own. The hook
      # `3.8. assets-build` in `.pre-commit-config.yaml` now runs ahead of hook
      # `6. mix-test-coverage`, and CI's separate `mix test --cover` step runs
      # after `pre-commit run --all-files`, so by the time this test executes the
      # bundles are on disk and their absence is a failure rather than silence.
      #
      # The consequence, stated plainly: `mix test` now depends on a prior
      # `mix assets.build`, which `mix setup` already runs. There is deliberately
      # no `File.exists?` guard and no tag excluded by default around this --
      # either would restore exactly the silence the gate closed.
      references =
        document
        |> LazyHTML.query("head script[src], head link[rel=stylesheet]")
        |> Enum.flat_map(fn node ->
          LazyHTML.attribute(node, "src") ++ LazyHTML.attribute(node, "href")
        end)
        |> Enum.filter(&String.starts_with?(&1, "/assets/"))

      # Named before they are fetched, so a query that matched nothing cannot
      # leave the loop below iterating over an empty list and passing: an
      # assertion nothing could reach reads as green forever. Membership rather
      # than equality, so a fourth asset is a reason to extend the loop and not
      # a reason for this to fail.
      for expected <- ["/assets/js/theme.js", "/assets/css/app.css", "/assets/js/app.js"] do
        assert expected in references
      end

      for reference <- references do
        served = get(build_conn(), reference)

        assert served.status == 200,
               "#{reference} is referenced by the root layout but answered #{served.status}"

        # A zero-byte file is served with a 200 all the same, and an empty
        # `theme.js` applies no theme.
        assert byte_size(served.resp_body) > 0, "#{reference} is served empty"
      end
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
      # actually run is no longer left unchecked: the gate puts `mix assets.build`
      # into the gate ahead of the suite, and "serves every asset it
      # references" above fails if the emitted file is missing or empty. The
      # configuration is still pinned here so that the entry point and the path
      # the layout asks for cannot drift apart without a named failure.
      assert "--outdir=../priv/static/assets/js" in args
    end

    test "theme selection and synchronization work when the JavaScript executes" do
      node =
        System.find_executable("node") || flunk("Node.js is required for the JavaScript tests")

      # System.cmd inherits the VM's environment even with env: []. Keep only
      # runtime basics; credentials and Node preload options must not reach it.
      env =
        System.get_env()
        |> Map.keys()
        |> Enum.reject(&(&1 in ~w(PATH TMPDIR TMP TEMP LANG LC_ALL TZ SystemRoot WINDIR)))
        |> Enum.map(&{&1, nil})

      {output, status} =
        System.cmd(node, ["--experimental-vm-modules", "--test", @theme_tests],
          stderr_to_stdout: true,
          env: env
        )

      assert status == 0, output
    end
  end

  describe "the theme toggle" do
    test "is reachable from every page", %{conn: conn} do
      # The restored listener is useless without a control that dispatches to
      # it, and the toggle was rendered by no template at all.
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
  end

  defp index_of(list, prefix), do: Enum.find_index(list, &String.starts_with?(&1, prefix))
end
