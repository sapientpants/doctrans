defmodule DoctransWeb.Plugs.LoopbackOnly do
  @moduledoc """
  Serves a route only to a connection from this machine's loopback interface.

  It guards the dev-only LiveDashboard (#281). Its shipped binding is loopback,
  but `PHX_BIND_IP=0.0.0.0` on a native `mix phx.server`, or a Compose port
  republished on a LAN address, puts the dashboard in front of every LAN peer:
  the process list, the ETS tables, the application environment and the
  request logger. The application itself is exposed in the same move, by
  design; a development tool that inspects the running VM does not need to be.

  The address checked is the TCP peer, `conn.remote_ip`, which nothing in this
  endpoint rewrites from a forwarded header, so a client cannot claim it. A
  request from anywhere else is refused with 403 and a plain-text reason, since
  the likeliest reader is the developer on the Compose stack: there the peer is
  Docker's gateway rather than loopback, and the dashboard is a native
  `mix phx.server` tool only.

  This plug does not reach `/live`, which Phoenix dispatches before any plug;
  `DoctransWeb.Live.Hooks.LoopbackOnly` applies the same check on mount.
  """
  @behaviour Plug

  import Bitwise, only: [>>>: 2]
  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if loopback?(conn.remote_ip) do
      conn
    else
      Logger.warning(
        "Refused #{conn.request_path} to #{:inet.ntoa(conn.remote_ip)}: " <>
          "the LiveDashboard is served to loopback connections only."
      )

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, refusal_message())
      |> halt()
    end
  end

  @doc """
  Whether `address` is a loopback address: `127.0.0.0/8`, `::1`, or the
  IPv4-mapped form of the former, which is how a listener bound on `::` sees
  an IPv4 loopback client. Anything else, `nil` included, is not.
  """
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: high >>> 8 == 127
  def loopback?(_address), do: false

  defp refusal_message do
    "Forbidden: the LiveDashboard is served to loopback connections only. Open it from " <>
      "the machine running a native `mix phx.server`; the Docker Compose stack does not " <>
      "serve it, because its connections arrive from Docker's gateway."
  end
end
