defmodule DoctransWeb.Plugs.LoopbackOnly do
  @moduledoc """
  Serves a route only to a connection from this machine's loopback interface.

  It guards the dev-only LiveDashboard (#281). Its shipped binding is loopback,
  but `PHX_BIND_IP=0.0.0.0` on a native `mix phx.server`, or a Compose port
  republished on a LAN address, puts the dashboard in front of every LAN peer:
  the process list, the ETS tables, the application environment and the
  request logger. The application itself is exposed in the same move, by
  design; a development tool that inspects the running VM does not need to be.

  This is a check on where a connection comes from, not on who is asking, so
  it is not the authentication AGENTS.md rules out: it holds a dev-only tool to
  the loopback bind that the deployment is already meant to provide.

  The address checked is the TCP peer, `conn.remote_ip`, which nothing in this
  endpoint rewrites from a forwarded header, so a client cannot claim it (the
  endpoint notes this beside its plugs). A request from anywhere else is
  refused with 403 and a plain-text reason, since the likeliest reader is the
  developer on the Compose stack: there the peer is Docker's gateway rather
  than loopback, so a route behind this plug is a native `mix phx.server`
  route only.

  This plug does not reach `/live`, which Phoenix dispatches before any plug;
  `DoctransWeb.Live.Hooks.LoopbackOnly` applies the same check on mount.
  """
  @behaviour Plug

  import Plug.Conn

  alias DoctransWeb.Loopback

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Loopback.loopback?(conn.remote_ip) do
      conn
    else
      Logger.warning(
        "Refused #{conn.request_path} to #{:inet.ntoa(conn.remote_ip)}, which is not a loopback peer."
      )

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, refusal_message())
      |> halt()
    end
  end

  defp refusal_message do
    "Forbidden: this page is served to loopback connections only. Open it from the machine " <>
      "running a native `mix phx.server`; under Docker Compose, connections arrive from " <>
      "Docker's gateway rather than from loopback."
  end
end
