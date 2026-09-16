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

  @doc """
  The response headers for `Plug.Conn.put_secure_browser_headers/2`.
  """
  def headers, do: %{"content-security-policy" => base()}

  @doc """
  The policy every route is served.

  Public for the test that pins it byte for byte against the literal the
  `:browser` pipeline carried before this module existed.
  """
  def base, do: render(@directives)

  @doc """
  The base policy plus exactly what LiveDashboard needs to render.

  `nonce` admits the dashboard's own inline script and style blocks, which carry
  it as an attribute; `data:` in `font-src` admits its embedded icon font. A
  nonce in `script-src` or `style-src` makes browsers ignore `'unsafe-inline'`
  in that directive, so neither policy can be widened by adding one later.
  """
  def dashboard(nonce) when is_binary(nonce) do
    additions = %{
      "script-src" => ["'nonce-#{nonce}'"],
      "style-src" => ["'nonce-#{nonce}'"],
      "font-src" => ["data:"]
    }

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
