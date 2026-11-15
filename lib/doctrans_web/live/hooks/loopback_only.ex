defmodule DoctransWeb.Live.Hooks.LoopbackOnly do
  @moduledoc """
  LiveView on_mount hook that applies `DoctransWeb.Plugs.LoopbackOnly` to the
  socket.

  The plug guards the dashboard's HTTP render, but a connected mount arrives
  over `/live`, which no plug sees. A LiveView session token is normally only
  obtainable from that render, except that the development `secret_key_base`
  is committed to a public repository, so anyone can mint one and mount the
  dashboard over the socket directly. The origin allowlist does not stop a
  client that is not a browser. This hook checks the socket's own TCP peer
  (`:peer_data`, which the endpoint's socket lists in its `connect_info`) and
  sends anything that is not loopback to the application's index.

  A missing peer counts as not loopback, so a socket configuration that stops
  supplying it closes the dashboard rather than opening it.
  """

  alias DoctransWeb.Plugs.LoopbackOnly

  def on_mount(:default, _params, _session, socket) do
    if LoopbackOnly.loopback?(peer_address(socket)) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp peer_address(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address
      _ -> nil
    end
  end
end
