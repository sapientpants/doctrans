defmodule DoctransWeb.Live.Hooks.LoopbackOnlyTest do
  use DoctransWeb.ConnCase, async: true

  # The connected mount arrives over `/live`, which no plug sees. A loopback
  # render followed by a socket from a LAN peer is the shape of a forged
  # session token, minted with the development secret the repository ships.
  test "sends a socket from a LAN peer away from the dashboard", %{conn: conn} do
    # `Phoenix.LiveViewTest` hands the connected mount this private key in
    # place of the request when it is set; the release in use has no public
    # setter for it.
    conn =
      put_private(conn, :live_view_connect_info, %{
        peer_data: %{address: {192, 168, 1, 20}, port: 50_000, ssl_cert: nil}
      })

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dev/dashboard/home")
  end

  test "mounts the dashboard over the socket for a loopback peer", %{conn: conn} do
    assert {:ok, _view, _html} = live(conn, ~p"/dev/dashboard/home")
  end
end
