defmodule DoctransWeb.MailboxCspTest do
  use DoctransWeb.ConnCase, async: true

  # U14. Swoosh's mailbox preview emits one inline `<script>` carrying a nonce
  # its plug reads out of `conn.assigns`, and nothing assigned it -- so under
  # `script-src 'self'` the browser refused it and the preview's timestamps,
  # text-body toggle and link handling silently did nothing. The same defect
  # U13 fixed for the dashboard, with one difference worth keeping in view:
  # Swoosh's template is EEx, which stringifies nil, so the broken page
  # rendered `nonce=""` where LiveDashboard's HEEx dropped the attribute.
  #
  # What has to line up is what lined up for the dashboard -- the nonce reaches
  # the markup, the same value reaches the header, and the relaxation stops at
  # this scope -- plus one thing that is U14's alone: the mailbox's exception is
  # a single source where the dashboard's is three, and the two must not drift
  # into each other.
  #
  # `dev_routes: true` in config/test.exs is what compiles these routes into the
  # test router at all.

  alias DoctransWeb.ContentSecurityPolicy
  alias DoctransWeb.Plugs.DashboardCsp
  alias DoctransWeb.Plugs.MailboxCsp

  describe "the mailbox preview" do
    setup %{conn: conn} do
      # Asserted against an empty mailbox deliberately. The inline script sits
      # outside the template's `if length(@emails) == 0` branch, so it renders
      # either way, and the app never delivers mail -- `Doctrans.Mailer` has no
      # callers and the test adapter never writes to Swoosh's local storage.
      conn = get(conn, ~p"/dev/mailbox")

      %{conn: conn, document: conn |> html_response(200) |> LazyHTML.from_document()}
    end

    test "serves the inline script the one nonce its own header admits", %{
      conn: conn,
      document: document
    } do
      inline = LazyHTML.query(document, "script:not([src])")

      assert inline |> LazyHTML.text() |> String.trim() != ""
      assert [nonce] = LazyHTML.attribute(inline, "nonce")

      # The empty string is the broken state here, not the absent attribute:
      # EEx renders `nonce=""` when the assign is missing, and an empty nonce
      # matches no source, so the script stays refused while the markup still
      # looks nonced.
      assert nonce != ""

      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "script-src 'self' 'nonce-#{nonce}'"
      assert policy == ContentSecurityPolicy.mailbox(nonce)
    end

    test "leaves the stylesheet's empty nonce alone, because it is not the defect", %{
      document: document
    } do
      # Swoosh nonces its stylesheet `<link>` too, and this plug deliberately
      # assigns no style key -- so that attribute stays empty. Named here so a
      # reader who greps the page for `nonce=""` and finds this one does not
      # read it as U14 having failed: the `<link>` is a URL-sourced same-origin
      # file, admitted by `style-src 'self'` whatever its nonce says.
      stylesheet = LazyHTML.query(document, "link[rel=stylesheet]")

      assert LazyHTML.attribute(stylesheet, "nonce") == [""]
      assert [href] = LazyHTML.attribute(stylesheet, "href")
      refute href =~ ~r{^https?://}
    end

    test "is served a policy one source wider than the base, and no wider", %{conn: conn} do
      assert [policy] = get_resp_header(conn, "content-security-policy")

      # The dashboard's other two relaxations are the ones that would arrive by
      # accident, since both policies are rendered from the same directive list.
      refute policy =~ "font-src 'self' data:"
      refute policy =~ "style-src 'self' 'nonce-"
      refute policy =~ "unsafe-inline"
    end
  end

  describe "every path under the forward" do
    test "carries the mailbox policy, the framed email bodies included", %{conn: conn} do
      # The plug sits on the scope, not on one route, so the widened header
      # reaches the preview's static assets and the `/:id/html` documents that
      # render email bodies. Asserted rather than left to the moduledoc,
      # because it is the claim U15 builds on: those responses each mint their
      # own nonce, so none of them is ever served the chrome's.
      conn = get(conn, ~p"/dev/mailbox/assets/app.css")

      assert conn.status == 200
      assert [policy] = get_resp_header(conn, "content-security-policy")

      nonce = conn.assigns[MailboxCsp.assign_keys().script]

      assert policy == ContentSecurityPolicy.mailbox(nonce)
      refute policy == ContentSecurityPolicy.base()
    end
  end

  describe "a second request for the mailbox" do
    test "is served a different nonce, and a header that matches its own body", %{conn: conn} do
      {first_nonce, first_policy} = fetch_mailbox(conn)
      {second_nonce, second_policy} = fetch_mailbox(conn)

      refute first_nonce == second_nonce
      assert first_policy =~ "'nonce-#{first_nonce}'"
      assert second_policy =~ "'nonce-#{second_nonce}'"
      refute first_policy =~ "'nonce-#{second_nonce}'"
      refute second_policy =~ "'nonce-#{first_nonce}'"
    end
  end

  describe "the two dev tools' scopes" do
    test "do not hand each other their policies", %{conn: conn} do
      # The pair U14 has to keep apart. One directive list renders both
      # exceptions, and both scopes live in the same `if dev_routes` block, so
      # a pipeline attached one line too high would widen the wrong route.
      mailbox = get(conn, ~p"/dev/mailbox")
      dashboard = get(conn, ~p"/dev/dashboard/home")

      assert [mailbox_policy] = get_resp_header(mailbox, "content-security-policy")
      assert [dashboard_policy] = get_resp_header(dashboard, "content-security-policy")

      assert mailbox_policy ==
               ContentSecurityPolicy.mailbox(mailbox.assigns[MailboxCsp.assign_keys().script])

      assert dashboard_policy ==
               ContentSecurityPolicy.dashboard(dashboard.assigns[DashboardCsp.assign_key()])

      refute mailbox_policy == dashboard_policy
    end

    test "do not hand each other their assigns", %{conn: conn} do
      mailbox = get(conn, ~p"/dev/mailbox")
      dashboard = get(conn, ~p"/dev/dashboard/home")

      refute Map.has_key?(mailbox.assigns, DashboardCsp.assign_key())
      refute Map.has_key?(dashboard.assigns, MailboxCsp.assign_keys().script)
    end
  end

  describe "DoctransWeb.Plugs.MailboxCsp" do
    test "publishes the nonce under the key it names, in the shape Swoosh reads" do
      # Swoosh pipes this option through `Enum.into/2`, so the bare atom
      # `live_dashboard` accepts would raise here. The shape is the contract.
      conn = run(build_conn(:get, "/dev/mailbox"))

      assert %{script: key} = MailboxCsp.assign_keys()
      assert is_binary(conn.assigns[key])
      assert conn.assigns[key] != ""
    end

    test "replaces the base policy rather than sending a second one" do
      # Two `content-security-policy` headers are intersected by the browser, so
      # appending instead of replacing would leave the stricter base policy in
      # force and refuse the nonced script anyway.
      conn =
        :get
        |> build_conn("/dev/mailbox")
        |> Phoenix.Controller.put_secure_browser_headers(ContentSecurityPolicy.headers())
        |> run()

      nonce = conn.assigns[MailboxCsp.assign_keys().script]

      assert get_resp_header(conn, "content-security-policy") ==
               [ContentSecurityPolicy.mailbox(nonce)]
    end

    test "assigns a fresh nonce on every call" do
      nonces =
        for _ <- 1..20,
            do: run(build_conn(:get, "/dev/mailbox")).assigns[MailboxCsp.assign_keys().script]

      assert nonces |> Enum.uniq() |> length() == 20
    end
  end

  defp run(conn), do: MailboxCsp.call(conn, MailboxCsp.init([]))

  # Returns the nonce the page rendered together with the policy that response
  # carried, so the two can only be compared within a single request.
  defp fetch_mailbox(conn) do
    conn = get(conn, ~p"/dev/mailbox")

    [nonce] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script:not([src])")
      |> LazyHTML.attribute("nonce")

    [policy] = get_resp_header(conn, "content-security-policy")

    {nonce, policy}
  end
end
