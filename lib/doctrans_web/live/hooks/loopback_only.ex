defmodule DoctransWeb.Live.Hooks.LoopbackOnly do
  @moduledoc """
  LiveView on_mount hook that applies `DoctransWeb.Plugs.LoopbackOnly` to the
  socket; the plug's moduledoc says why.

  The plug guards the HTTP render, but a connected mount arrives over `/live`,
  which no plug sees. A LiveView session token is normally only obtainable from
  that render, but the render is not the only way to get one: the development
  `secret_key_base` was once committed to a public repository (#333), and any
  key that leaks lets its holder mint a token and mount over the socket
  directly, where the origin allowlist does not stop a client that is not a
  browser. The guard therefore does not rest on the key staying secret. This
  hook checks the socket's own TCP peer (`:peer_data`, which the endpoint's
  socket lists in its `connect_info`) and sends anything that is not loopback
  to the application's index.

  A missing peer counts as not loopback, so a socket configuration that stops
  supplying it closes the route rather than opening it.
  """

  alias DoctransWeb.Loopback

  def on_mount(:default, _params, _session, socket) do
    if Loopback.loopback?(peer_address(socket)) do
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
