defmodule DoctransWeb.Plugs.AllowedHostTest do
  use Doctrans.EnvCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 2]

  alias DoctransWeb.Plugs.AllowedHost

  # The list under test is the one `config/test.exs` states: the loopback names
  # and `www.example.com`, the host `Phoenix.ConnTest` gives its connections.
  # Which names `config/runtime.exs` puts on the list for a deployment is
  # `Doctrans.RuntimeConfigTest`'s concern.

  defp run(host) do
    conn = %{conn(:get, "/") | host: host}
    {conn, _log} = with_log(fn -> AllowedHost.call(conn, AllowedHost.init([])) end)
    conn
  end

  test "a request for a listed host passes through untouched" do
    for host <- ["www.example.com", "localhost", "127.0.0.1", "[::1]"] do
      conn = run(host)

      refute conn.halted
      assert conn.state == :unset
    end
  end

  # Browsers send the Host in lower case; a client that does not is still
  # naming the same host.
  test "the host is compared case-insensitively" do
    refute run("WWW.Example.COM").halted
  end

  test "a request for an unlisted host is refused with 421 before anything else runs" do
    conn = run("attacker.example")

    assert conn.halted
    assert conn.status == 421
    assert conn.resp_body =~ "attacker.example"
    assert conn.resp_body =~ "PHX_HOST"
    assert ["text/plain" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
  end

  # A rebinding page's hostname can be made to contain a listed name; the match
  # is on the whole host, never on a prefix or suffix of it.
  test "a host that merely contains a listed name is refused" do
    for host <- ["localhost.attacker.example", "attacker-localhost", "www.example.com.evil"] do
      assert run(host).status == 421, "#{host} was admitted"
    end
  end

  test "the refusal names the host in the log, for an operator who mistyped PHX_HOST" do
    conn = %{conn(:get, "/") | host: "doctrans.lan"}

    {_conn, log} = with_log(fn -> AllowedHost.call(conn, []) end)

    assert log =~ "doctrans.lan"
    assert log =~ "PHX_HOST"
  end
end
