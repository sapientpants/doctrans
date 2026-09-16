defmodule DoctransWeb.ContentSecurityPolicy do
  @moduledoc """
  The single place the application's Content-Security-Policy is written.

  `headers/0` is what the `:browser` pipeline serves to every route, and it is
  the policy: `'self'` for every executable source, no `'unsafe-inline'`, and no
  nonce. The exceptions are `dashboard/1` and `mailbox/1`, and they exist only
  because the markup of two dev-only dependencies is not ours to change.

  `dashboard/1` is the wider of the two: LiveDashboard's layout emits an inline
  `<script>`, its usage cards emit inline `<style>` blocks, and its stylesheet
  embeds the icon font as a `data:` URI. The first two carry the per-request
  nonce the route is told to read; the third is why `font-src` gains `data:`.

  `mailbox/1` adds a single source. Swoosh's preview emits one inline
  `<script>` and no `<style>` at all, and its stylesheet embeds nothing -- so
  the nonce in `script-src` is the whole exception. The asymmetry is the point:
  each policy is the base plus what that one tool demonstrably needs, and
  neither inherits the other's relaxations.

  Every policy is rendered from one directive list, so an exception can only
  ever be the base plus its own additions. They are applied by
  `DoctransWeb.Plugs.DashboardCsp` and `DoctransWeb.Plugs.MailboxCsp`, each
  inside its own dev-only scope (`/dev/dashboard`, `/dev/mailbox`), so every
  other route is served `headers/0` unchanged.

  The router calls `headers/0` in a `plug` option, which Phoenix evaluates at
  compile time, so this is a compile-time dependency of the router: keep this
  module a leaf. It depends on nothing today, which is what keeps that edge
  cheap and keeps it out of the cycle gate.
  """

  @directives [
    {"default-src", ["'self'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'"]},
    {"img-src", ["'self'", "data:", "blob:"]},
    {"font-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"frame-ancestors", ["'none'"]},
    {"base-uri", ["'self'"]},
    {"form-action", ["'self'"]}
  ]

  @directive_names Enum.map(@directives, &elem(&1, 0))

  # What each exception adds, kept as its own list so the directive names can be
  # checked against `@directives` here rather than only by a test asserting the
  # rendered string. `:nonce` stands in for the per-request value.
  @dashboard_additions [
    {"script-src", :nonce},
    {"style-src", :nonce},
    {"font-src", ["data:"]}
  ]

  # One source, not three. Swoosh's only nonced `<style>` is a URL-sourced
  # stylesheet that `style-src 'self'` already admits, and its CSS embeds no
  # font, so neither of the dashboard's other two relaxations is earned here.
  @mailbox_additions [
    {"script-src", :nonce}
  ]

  # A directive renamed in one list and not the other would drop its addition
  # with no error at all, and a dropped nonce refuses the very markup it was
  # minted for -- the one direction in which a policy must never fail quietly.
  for {name, additions} <- [dashboard: @dashboard_additions, mailbox: @mailbox_additions],
      {directive, _sources} <- additions,
      directive not in @directive_names do
    raise "#{name}/1 widens #{directive}, which is not a directive in @directives"
  end

  @doc """
  A fresh nonce for one request.

  144 bits from `:crypto.strong_rand_bytes/1`, comfortably over the 128 the CSP
  specification asks for. A nonce a page's own markup can be guessed against is
  a nonce in name only, and one reused across responses is worth no more than
  `'unsafe-inline'` -- so this is called per request, by each plug that heads a
  policy carrying it.
  """
  def nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc """
  The response headers for `Plug.Conn.put_secure_browser_headers/2`.
  """
  def headers, do: %{"content-security-policy" => base()}

  @doc """
  The policy every route outside the dev tools' own scopes is served.

  Public so tests can pin it byte for byte against the literal the `:browser`
  pipeline carried before this module existed, and so they can assert that the
  routes outside `/dev/dashboard` and `/dev/mailbox` are still served exactly
  it.
  """
  def base, do: render(@directives)

  @doc """
  The base policy plus exactly what LiveDashboard needs to render.

  `nonce` admits the dashboard's own inline script and style blocks, which carry
  it as an attribute; `data:` in `font-src` admits its embedded icon font.

  Adding `'unsafe-inline'` to *this* policy would be dead text, because a nonce
  in `script-src` or `style-src` makes browsers ignore it in that directive.
  That argument covers this policy's two nonced directives and nothing beyond
  them: `base/0` carries no nonce at all, and `mailbox/1` carries one only in
  `script-src`. An `'unsafe-inline'` added to the shared `@directives` would
  therefore be live in `style-src` on both, and live in `script-src` on the
  base -- which is what `base/0`'s own test refuses.

  A nonce admits `<style>` elements, not `style` attributes. No page this
  application mounts uses one; `live_layered_graph/1` on a custom page would,
  and would need `style-src-attr` rather than another source here.
  """
  def dashboard(nonce) when is_binary(nonce), do: widen(@dashboard_additions, nonce)

  @doc """
  The base policy plus the one source Swoosh's mailbox preview needs.

  That source is the nonce in `script-src`, for the single inline `<script>`
  the preview's template emits unconditionally.

  What is deliberately absent matters as much. There is no `font-src data:`:
  Swoosh's stylesheet embeds nothing, so the dashboard's third relaxation is
  unearned here. There is no nonce in `style-src` either -- the template does
  put one on its stylesheet `<link>`, but that is a URL-sourced same-origin
  file `'self'` already admits, so the empty attribute it renders there is
  inert rather than the defect this item fixed. A reader who finds `nonce=""`
  on that `<link>` is looking at nothing.
  """
  def mailbox(nonce) when is_binary(nonce), do: widen(@mailbox_additions, nonce)

  defp widen(additions, nonce) do
    additions =
      Map.new(additions, fn
        {directive, :nonce} -> {directive, ["'nonce-#{nonce}'"]}
        {directive, sources} -> {directive, sources}
      end)

    @directives
    |> Enum.map(fn {directive, sources} ->
      {directive, sources ++ Map.get(additions, directive, [])}
    end)
    |> render()
  end

  defp render(directives) do
    Enum.map_join(directives, "; ", fn {directive, sources} ->
      Enum.join([directive | sources], " ")
    end)
  end
end
