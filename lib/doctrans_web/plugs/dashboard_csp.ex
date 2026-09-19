defmodule DoctransWeb.Plugs.DashboardCsp do
  @moduledoc """
  Gives the dev-only LiveDashboard the CSP nonce its layout already renders.

  LiveDashboard's layout emits `<script nonce={csp_nonce(@conn, :script)}>` and
  its cards emit nonced `<style>` blocks, but it reads those nonces out of
  `conn.assigns` under a key the route has to name. With no key named that
  expression is `nil`, HEEx drops a `nil` attribute rather than rendering it
  empty, and the browser refuses the script -- which is what the `:browser`
  pipeline's `script-src 'self'` is supposed to do. The broken page carries no
  `nonce=""` to grep for: the attribute is simply absent.

  This plug mints one nonce per request, assigns it under `:csp_nonce`
  for `live_dashboard`'s `:csp_nonce_assign_key`, and replaces the response's
  policy with `DoctransWeb.ContentSecurityPolicy.dashboard/1`, which is the base
  policy plus that nonce. Assigning and heading must happen in the same request:
  LiveDashboard snapshots the assign into the LiveView session at dead render
  (`Phoenix.LiveDashboard.Router`), so the socket keeps using the nonce that the
  document's own header admitted.

  It runs after the `:browser` pipeline and only inside the dashboard's scope,
  so it is the only place the base policy is ever overridden.
  """
  @behaviour Plug

  import Plug.Conn

  alias DoctransWeb.ContentSecurityPolicy

  @assign_key :csp_nonce

  @doc """
  The assign the nonce is published under.

  The router passes this to `live_dashboard`'s `:csp_nonce_assign_key` rather
  than repeating the atom, so the two sides cannot drift into the empty-nonce
  state this plug exists to prevent.
  """
  def assign_key, do: @assign_key

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = ContentSecurityPolicy.nonce()

    conn
    |> assign(@assign_key, nonce)
    |> put_resp_header("content-security-policy", ContentSecurityPolicy.dashboard(nonce))
  end
end
