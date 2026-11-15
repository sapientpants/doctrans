defmodule DoctransWeb.Plugs.LoopbackOnlyTest do
  use DoctransWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  @lan_peer {192, 168, 1, 20}

  test "the dashboard renders for a loopback client", %{conn: conn} do
    assert conn |> get(~p"/dev/dashboard/home") |> html_response(200)
  end

  test "the dashboard is refused with 403 to a LAN peer, before it runs", %{conn: conn} do
    {conn, log} =
      with_log(fn -> get(%{conn | remote_ip: @lan_peer}, ~p"/dev/dashboard/home") end)

    assert conn.halted
    assert response(conn, 403) =~ "loopback"
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    assert log =~ "192.168.1.20"
  end

  # The guard is the dashboard's, not the application's: a LAN bind is how a
  # user deliberately shares the app itself.
  test "the application's own routes still serve a LAN peer", %{conn: conn} do
    assert %{conn | remote_ip: @lan_peer} |> get(~p"/") |> html_response(200)
  end
end
