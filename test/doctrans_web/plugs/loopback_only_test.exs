defmodule DoctransWeb.Plugs.LoopbackOnlyTest do
  use DoctransWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias DoctransWeb.Plugs.LoopbackOnly

  @lan_peer {192, 168, 1, 20}

  describe "loopback?/1" do
    test "admits the IPv4 loopback block, ::1 and their IPv4-mapped form" do
      for address <- [
            {127, 0, 0, 1},
            {127, 255, 0, 9},
            {0, 0, 0, 0, 0, 0, 0, 1},
            # ::ffff:127.0.0.1, as a listener bound on `::` sees it
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
          ] do
        assert LoopbackOnly.loopback?(address), "#{inspect(address)} was refused"
      end
    end

    test "refuses every other address, and no address at all" do
      for address <- [
            @lan_peer,
            {172, 17, 0, 1},
            {0, 0, 0, 0},
            {128, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            # ::ffff:192.168.1.20
            {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0114},
            nil
          ] do
        refute LoopbackOnly.loopback?(address), "#{inspect(address)} was admitted"
      end
    end
  end

  describe "the dashboard" do
    test "renders for a loopback client", %{conn: conn} do
      assert conn |> get(~p"/dev/dashboard/home") |> html_response(200)
    end

    test "is refused with 403 to a LAN peer, before the dashboard runs", %{conn: conn} do
      {conn, log} =
        with_log(fn -> get(%{conn | remote_ip: @lan_peer}, ~p"/dev/dashboard/home") end)

      assert conn.halted
      assert response(conn, 403) =~ "loopback"
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      assert log =~ "192.168.1.20"
    end

    # The connected mount arrives over `/live`, which no plug sees. A loopback
    # render followed by a socket from a LAN peer is the shape of a forged
    # session token, minted with the development secret the repository ships.
    test "sends a socket from a LAN peer away from the dashboard", %{conn: conn} do
      # `Phoenix.LiveViewTest` hands the connected mount this private key in
      # place of the request when it is set; the release in use has no public
      # setter for it.
      conn =
        put_private(conn, :live_view_connect_info, %{
          peer_data: %{address: @lan_peer, port: 50_000, ssl_cert: nil}
        })

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dev/dashboard/home")
    end

    test "mounts over the socket for a loopback peer", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/dev/dashboard/home")
    end
  end

  # The guard is the dashboard's, not the application's: a LAN bind is how a
  # user deliberately shares the app itself.
  test "the application's own routes still serve a LAN peer", %{conn: conn} do
    assert %{conn | remote_ip: @lan_peer} |> get(~p"/") |> html_response(200)
  end
end
