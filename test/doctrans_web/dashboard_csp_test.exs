defmodule DoctransWeb.DashboardCspTest do
  use DoctransWeb.ConnCase, async: true

  # U13. LiveDashboard's layout renders an inline `<script>` and its cards
  # render inline `<style>` blocks, both of which the application's
  # `script-src 'self'` / `style-src 'self'` refuses. The inline script is the
  # one that matters: it defines `window.LiveDashboard`, which the deferred
  # bundle reads on load, so refusing it breaks the page's JavaScript before the
  # socket is reached. The fix is a per-request nonce the dashboard's own markup
  # already knows how to carry. Three things have to line
  # up for it to work, and none of them is visible from either side alone: the
  # nonce has to reach the markup, the same value has to reach the header, and
  # the relaxation has to stop at the dashboard's scope. All three are pinned
  # here, because a browser is the only other thing that would notice.
  #
  # `dev_routes: true` in config/test.exs is what compiles these routes into the
  # test router at all.

  alias DoctransWeb.ContentSecurityPolicy
  alias DoctransWeb.Plugs.DashboardCsp

  describe "the dashboard page" do
    setup %{conn: conn} do
      # `/dev/dashboard` only redirects; `/home` is the first page that renders,
      # and rendering is the whole subject here.
      conn = get(conn, ~p"/dev/dashboard/home")

      %{conn: conn, document: conn |> html_response(200) |> LazyHTML.from_document()}
    end

    test "serves every nonce attribute the one value its own header admits", %{
      conn: conn,
      document: document
    } do
      nonces = document |> LazyHTML.query("[nonce]") |> LazyHTML.attribute("nonce")

      # More than nothing: an assign key the router never named renders the
      # attribute empty rather than absent, which is exactly the broken state
      # and looks like a nonced page from a distance.
      assert nonces != []
      refute "" in nonces
      assert [nonce] = Enum.uniq(nonces)

      # One value per document, not one per element: the header can only name a
      # fixed set, and the plug mints exactly one.
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "script-src 'self' 'nonce-#{nonce}'"
      assert policy =~ "style-src 'self' 'nonce-#{nonce}'"

      # The third widened source, asserted on the header the route actually
      # serves: LiveDashboard's stylesheet embeds its icon font as a `data:`
      # URI, and without this the icons come back as empty boxes -- the one
      # relaxation whose absence breaks nothing loudly enough to notice.
      assert policy =~ "font-src 'self' data:"
    end

    test "nonces the inline script and the stylesheet the page cannot load without", %{
      document: document
    } do
      # Named individually rather than left to the count above. The inline
      # `<script>` is the one element whose failure is silent and total -- it
      # defines `window.LiveDashboard` before the deferred bundle reads it -- so
      # a future layout that drops its nonce while other elements keep theirs
      # would still satisfy a purely aggregate assertion.
      inline = LazyHTML.query(document, "head script:not([src])")
      sourced = LazyHTML.query(document, "head script[src]")
      stylesheet = LazyHTML.query(document, "head link[rel=stylesheet]")

      assert inline |> LazyHTML.text() |> String.trim() != ""
      assert [nonce] = LazyHTML.attribute(inline, "nonce")
      assert nonce != ""

      # The dashboard's own bundle and stylesheet are served from its route, so
      # `'self'` already admits them whatever their nonce says -- a source list
      # is a disjunction, and a URL-sourced element that matches one expression
      # is allowed. They are asserted anyway as the check that one nonce is
      # minted per document rather than one per element.
      assert LazyHTML.attribute(sourced, "nonce") == [nonce]
      assert LazyHTML.attribute(stylesheet, "nonce") == [nonce]
    end

    test "hands the connected LiveView the nonce the document's header already admitted", %{
      conn: conn
    } do
      # LiveDashboard snapshots the assign into the LiveView session during the
      # dead render, so the socket keeps rendering the dead render's nonce. If
      # the plug ever minted a second nonce for the connect, or the socket fell
      # back to none, the live page's inline styles would be refused against a
      # header that is never sent again -- a break nothing but a browser sees,
      # since the dead render above would still pass.
      assert [policy] = get_resp_header(conn, "content-security-policy")

      {:ok, _view, html} = live(conn)

      nonces =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("[nonce]")
        |> LazyHTML.attribute("nonce")
        |> Enum.uniq()

      assert nonces != []

      for nonce <- nonces do
        assert policy =~ "'nonce-#{nonce}'", "the connected render used a nonce the header omits"
      end
    end
  end

  describe "a second request for the dashboard" do
    test "is served a different nonce, and a header that matches its own body", %{conn: conn} do
      # A nonce reused across requests is worth no more than `'unsafe-inline'`:
      # an attacker who can read one response can write markup the next one
      # admits. The pairing matters as much as the difference -- minting per
      # request but heading once would leave the second page refused.
      {first_nonce, first_policy} = fetch_dashboard(conn)
      {second_nonce, second_policy} = fetch_dashboard(conn)

      refute first_nonce == second_nonce
      assert first_policy =~ "'nonce-#{first_nonce}'"
      assert second_policy =~ "'nonce-#{second_nonce}'"
      refute first_policy =~ "'nonce-#{second_nonce}'"
      refute second_policy =~ "'nonce-#{first_nonce}'"
    end
  end

  describe "every other route" do
    test "is served the base policy, with no usable nonce on the page", %{conn: conn} do
      # The regression guard for the scope split. `/dev/mailbox` used to share
      # the dashboard's scope, so the obvious way to wire the nonce in -- adding
      # the plug to the existing `/dev` scope -- would hand the relaxed policy
      # to a page that has no need of it. The application's own routes are here
      # for the same reason at the other end: the U13 refactor rewrote the
      # pipeline every one of them passes through.
      for path <- [~p"/", ~p"/search", ~p"/dev/mailbox"] do
        conn = get(conn, path)

        assert conn.status == 200

        assert get_resp_header(conn, "content-security-policy") == [ContentSecurityPolicy.base()],
               "#{path} is not served the base policy"

        nonces =
          conn
          |> response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query("[nonce]")
          |> LazyHTML.attribute("nonce")

        # Emptiness rather than absence: Swoosh's mailbox template nonces its
        # own inline script and style unconditionally, so `/dev/mailbox` carries
        # empty nonce attributes whether or not a key is configured -- and an
        # empty one admits nothing, which is the point. On the application's own
        # routes a non-empty value would mean the dashboard's plug had escaped
        # its scope; on `/dev/mailbox` the header assertion above is what guards
        # that, since Swoosh reads its own assign keys and would render empty
        # nonces even if the plug did leak in.
        assert Enum.uniq(nonces) -- [""] == [],
               "#{path} renders a nonce its policy does not admit"
      end
    end

    test "does not carry the dashboard's assign either", %{conn: conn} do
      # The header is the enforcement, but the assign is what a template could
      # pick up. Neither should exist outside the dashboard's scope.
      conn = get(conn, ~p"/")

      refute Map.has_key?(conn.assigns, DashboardCsp.assign_key())
    end
  end

  describe "DoctransWeb.Plugs.DashboardCsp" do
    test "publishes the nonce under the assign key it names" do
      # The key is the plug's only contract with LiveDashboard, which reads
      # `conn.assigns[key]` and renders `nonce=""` if nothing is there -- a
      # failure with no server-side symptom at all. The router reads the key
      # from `assign_key/0` rather than repeating it, so the pairing is checked
      # by the compiler; what is left to check here is that the plug actually
      # publishes under it.
      conn = run(build_conn(:get, "/dev/dashboard/home"))

      assert is_binary(conn.assigns[DashboardCsp.assign_key()])
      assert conn.assigns[DashboardCsp.assign_key()] != ""
    end

    test "replaces the base policy rather than sending a second one" do
      # Two `content-security-policy` headers are intersected by the browser, so
      # appending instead of replacing would leave the stricter base policy in
      # force and refuse the nonced script anyway -- while every header the test
      # looked at contained the nonce.
      conn =
        :get
        |> build_conn("/dev/dashboard/home")
        |> Phoenix.Controller.put_secure_browser_headers(ContentSecurityPolicy.headers())
        |> run()

      nonce = conn.assigns[DashboardCsp.assign_key()]

      assert get_resp_header(conn, "content-security-policy") ==
               [ContentSecurityPolicy.dashboard(nonce)]
    end

    test "mints a fresh, unguessable nonce on every call" do
      nonces = for _ <- 1..20, do: run(build_conn(:get, "/")).assigns[DashboardCsp.assign_key()]

      assert nonces |> Enum.uniq() |> length() == 20

      # 18 random bytes, base64-encoded. The CSP specification asks for at least
      # 128 bits; anything a page's own markup can be guessed against is a nonce
      # in name only.
      for nonce <- nonces do
        assert {:ok, bytes} = Base.decode64(nonce)
        assert byte_size(bytes) >= 16
      end
    end
  end

  defp run(conn), do: DashboardCsp.call(conn, DashboardCsp.init([]))

  # Returns the nonce the page rendered together with the policy that response
  # carried, so the two can only be compared within a single request.
  defp fetch_dashboard(conn) do
    conn = get(conn, ~p"/dev/dashboard/home")

    [nonce] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("[nonce]")
      |> LazyHTML.attribute("nonce")
      |> Enum.uniq()

    [policy] = get_resp_header(conn, "content-security-policy")

    {nonce, policy}
  end
end
