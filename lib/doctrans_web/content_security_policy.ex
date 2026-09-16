defmodule DoctransWeb.ContentSecurityPolicy do
  @moduledoc """
  The single place the application's Content-Security-Policy is written.

  `headers/0` is what the `:browser` pipeline serves to every route, and it is
  the policy: `'self'` for every executable source, no `'unsafe-inline'`, and no
  nonce. `dashboard/1` is the one exception, and it exists only because
  LiveDashboard's markup is not ours to change: its layout emits an inline
  `<script>`, its usage cards emit inline `<style>` blocks, and its stylesheet
  embeds the icon font as a `data:` URI. The first two carry the per-request
  nonce the route is told to read; the third is why `font-src` gains `data:`.

  Both policies are rendered from one directive list so the exception can only
  ever be the base plus what the dashboard demonstrably needs. The dashboard
  policy is applied by `DoctransWeb.Plugs.DashboardCsp`, inside the dev-only
  `/dev/dashboard` scope, so every other route is served `headers/0` unchanged.

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

  # What `dashboard/1` adds, kept as its own list so the directive names can be
  # checked against `@directives` here rather than only by a test asserting the
  # rendered string. `:nonce` stands in for the per-request value.
  @dashboard_additions [
    {"script-src", :nonce},
    {"style-src", :nonce},
    {"font-src", ["data:"]}
  ]

  # A directive renamed in one list and not the other would drop its addition
  # with no error at all, and a dropped nonce refuses the very markup it was
  # minted for -- the one direction in which a policy must never fail quietly.
  for {directive, _sources} <- @dashboard_additions, directive not in @directive_names do
    raise "dashboard/1 widens #{directive}, which is not a directive in @directives"
  end

  @doc """
  A fresh nonce for one request.

  144 bits from `:crypto.strong_rand_bytes/1`, comfortably over the 128 the CSP
  specification asks for. A nonce a page's own markup can be guessed against is
  a nonce in name only, and one reused across responses is worth no more than
  `'unsafe-inline'` -- so this is called per request, by the plug that heads the
  policy carrying it.
  """
  def nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc """
  The response headers for `Plug.Conn.put_secure_browser_headers/2`.
  """
  def headers, do: %{"content-security-policy" => base()}

  @doc """
  The policy every route but the dashboard is served.

  Public so tests can pin it byte for byte against the literal the `:browser`
  pipeline carried before this module existed, and so they can assert that the
  routes outside the dashboard's scope are still served exactly it.
  """
  def base, do: render(@directives)

  @doc """
  The base policy plus exactly what LiveDashboard needs to render.

  `nonce` admits the dashboard's own inline script and style blocks, which carry
  it as an attribute; `data:` in `font-src` admits its embedded icon font.

  Adding `'unsafe-inline'` to *this* policy would be dead text, because a nonce
  in `script-src` or `style-src` makes browsers ignore it in that directive.
  That argument stops here: `base/0` carries no nonce, so an `'unsafe-inline'`
  added to `@directives` would take full effect on every other route, which is
  what `base/0`'s own test refuses.

  A nonce admits `<style>` elements, not `style` attributes. No page this
  application mounts uses one; `live_layered_graph/1` on a custom page would,
  and would need `style-src-attr` rather than another source here.
  """
  def dashboard(nonce) when is_binary(nonce), do: widen(@dashboard_additions, nonce)

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
