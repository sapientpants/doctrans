defmodule Doctrans.RuntimeConfigTest do
  # Reads `config/runtime.exs` directly: `mix test` never evaluates the storage
  # root and listener blocks it defines, so the operator-facing variables are
  # otherwise untested. The listener is read for :dev and :prod alike, since the
  # one parse serves both.
  #
  # `async: false`: the OS environment it sets is shared by the whole VM.
  use Doctrans.EnvCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias DoctransWeb.Plugs.AllowedHost
  alias Phoenix.Socket.Transport

  @env_keys ~w(DOCTRANS_DATA_DIR DATABASE_URL SECRET_KEY_BASE DOCTRANS_ENV_FILE
               PHX_BIND_IP PHX_HOST PHX_SCHEME PORT)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://unused/unused",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      # Keep the developer's own `.env` out of the configuration under test.
      "DOCTRANS_ENV_FILE" => Path.join(System.tmp_dir!(), "missing-#{Uniq.UUID.uuid7()}.env")
    })

    Enum.each(~w(DOCTRANS_DATA_DIR PHX_BIND_IP PHX_HOST PHX_SCHEME PORT), &System.delete_env/1)
    :ok
  end

  defp read_config(env) do
    Path.expand("../../config/runtime.exs", __DIR__)
    |> Config.Reader.read!(env: env)
  end

  defp upload_dir(env), do: get_in(read_config(env), [:doctrans, :uploads, :upload_dir])

  defp endpoint(env \\ :prod, key),
    do: get_in(read_config(env), [:doctrans, DoctransWeb.Endpoint, key])

  defp allowed_hosts(env), do: get_in(read_config(env), [:doctrans, :allowed_hosts])

  test "an absolute DOCTRANS_DATA_DIR becomes the storage root" do
    System.put_env("DOCTRANS_DATA_DIR", "/srv/doctrans-data/")

    assert upload_dir(:prod) == "/srv/doctrans-data"
  end

  test "an unset DOCTRANS_DATA_DIR leaves the storage root to the default" do
    assert upload_dir(:prod) == nil
  end

  test "a relative DOCTRANS_DATA_DIR is rejected rather than resolved against the cwd" do
    System.put_env("DOCTRANS_DATA_DIR", "data")

    assert_raise RuntimeError, ~r/must be an absolute path/, fn -> upload_dir(:prod) end
  end

  test "an empty DOCTRANS_DATA_DIR is rejected rather than silently meaning the cwd" do
    System.put_env("DOCTRANS_DATA_DIR", "")

    assert_raise RuntimeError, ~r/set but empty/, fn -> upload_dir(:prod) end
  end

  # The suite deletes directories beneath its storage root. Honouring the
  # variable in :test would let `mix test` erase the documents of an operator who
  # set it in their environment or `.env`.
  test "DOCTRANS_DATA_DIR never repoints the storage root in the test environment" do
    System.put_env("DOCTRANS_DATA_DIR", "/srv/doctrans-data")

    assert upload_dir(:test) == nil
  end

  test "an invalid DOCTRANS_DATA_DIR is ignored in the test environment" do
    System.put_env("DOCTRANS_DATA_DIR", "")

    assert upload_dir(:test) == nil
  end

  # Bandit types `:ip` as `:inet.socket_address()` and hands it to
  # `:gen_tcp.listen/2`, which exits with :badarg on a string. A textual address
  # here is not a cosmetic problem: the endpoint never starts.
  #
  # The interface the endpoint listens on is the one setting that decides
  # whether an app with no authentication is reachable from the LAN, so every
  # case runs for development and production alike.
  for env <- [:dev, :prod] do
    describe "PHX_BIND_IP in #{env}" do
      @env env

      test "defaults to the loopback address as a tuple, not a string" do
        assert endpoint(@env, :http)[:ip] == {127, 0, 0, 1}
      end

      test "parses an explicit IPv4 literal" do
        System.put_env("PHX_BIND_IP", "0.0.0.0")

        assert endpoint(@env, :http)[:ip] == {0, 0, 0, 0}
      end

      test "parses an IPv6 literal" do
        System.put_env("PHX_BIND_IP", "::1")

        assert endpoint(@env, :http)[:ip] == {0, 0, 0, 0, 0, 0, 0, 1}
      end

      test "a value that is not an address literal is rejected by name" do
        System.put_env("PHX_BIND_IP", "localhost")

        assert_raise RuntimeError, ~r/PHX_BIND_IP.*localhost/s, fn -> endpoint(@env, :http) end
      end

      # `System.get_env/1 || default` treats "" as a value, so an explicitly
      # empty setting does not fall back to loopback — it fails to parse.
      # Refusing to start is the right answer either way, and the README says
      # so; this pins it rather than leaving the documented behaviour to the
      # shape of an `||`.
      test "an explicitly empty value is rejected rather than falling back" do
        System.put_env("PHX_BIND_IP", "")

        assert_raise RuntimeError, ~r/PHX_BIND_IP must be an IPv4 or IPv6 address literal/, fn ->
          endpoint(@env, :http)
        end
      end

      test "PORT chooses the listening port" do
        System.put_env("PORT", "4321")

        assert endpoint(@env, :http)[:port] == 4321
      end
    end
  end

  # The suite's own endpoint is configured in `config/test.exs` and never
  # serves; the listener block must not reach into it.
  test "the test environment keeps the listener from config/test.exs" do
    System.put_env("PHX_BIND_IP", "0.0.0.0")
    System.put_env("PORT", "4321")

    assert endpoint(:test, :http) == nil
    assert endpoint(:test, :check_origin) == nil
    assert allowed_hosts(:test) == nil
  end

  # Runs the configured allowlist through the check Phoenix applies to a
  # websocket handshake, so the assertions are about which browsers connect
  # rather than about the shape of a list. The endpoint only serves as the
  # cache the transport parses the list into; `:check_origin` is passed as the
  # transport option, which takes precedence over the endpoint's own setting.
  defp admits?(origins, origin) do
    conn = put_req_header(conn(:get, "/live/websocket"), "origin", origin)

    {result, _log} =
      with_log(fn ->
        Transport.check_origin(
          conn,
          Phoenix.LiveView.Socket,
          DoctransWeb.Endpoint,
          [check_origin: origins],
          & &1
        )
      end)

    not result.halted
  end

  @loopback_origins ~w(//localhost //127.0.0.1 //[::1])

  # Development used to set `check_origin: false` (#259; the comment on the
  # allowlist in `config/runtime.exs` tells the story). The list is the same in
  # every environment that serves, so the two quickstarts (`mix phx.server`,
  # `docker compose up`) are covered along with the release.
  for env <- [:dev, :prod] do
    describe "the socket origin allowlist in #{env}" do
      @env env

      test "names the loopback origins a local browser types, and nothing else" do
        assert endpoint(@env, :check_origin) == @loopback_origins
      end

      test "admits a local browser on any port and refuses a foreign origin" do
        origins = endpoint(@env, :check_origin)

        assert admits?(origins, "http://localhost:4000")
        assert admits?(origins, "http://127.0.0.1:4321")
        assert admits?(origins, "http://[::1]:4000")
        refute admits?(origins, "http://attacker.example:4000")
        refute admits?(origins, "http://localhost.attacker.example:4000")
      end

      test "PHX_HOST adds the name the browser types for a deployment" do
        System.put_env("PHX_HOST", "doctrans.lan")

        origins = endpoint(@env, :check_origin)

        assert "//doctrans.lan" in origins
        assert admits?(origins, "http://doctrans.lan:4000")
        refute admits?(origins, "http://attacker.example:4000")
      end

      # Browsers send the Origin host in lower case and Phoenix compares it
      # exactly, so the entry is lower-cased however the operator typed it.
      test "a PHX_HOST typed in mixed case still admits the browser's lower-case origin" do
        System.put_env("PHX_HOST", "Doctrans.LAN")

        assert admits?(endpoint(@env, :check_origin), "http://doctrans.lan:4000")
      end

      test "a bracketed IPv6 PHX_HOST is admitted as the browser types it" do
        System.put_env("PHX_HOST", "[fe80::1]")

        assert admits?(endpoint(@env, :check_origin), "http://[fe80::1]:4000")
      end

      # `URI.parse/1` reads "fe80::1" as host "fe80" and "http://doctrans.lan"
      # as host "http": entries no browser's Origin would match, which would
      # leave the page rendering once and never connecting, with nothing said.
      for bad <- [
            "",
            "fe80::1",
            "http://doctrans.lan",
            "doctrans.lan:4000",
            "doctrans.lan/app",
            "bad host"
          ] do
        test "PHX_HOST #{inspect(bad)} is rejected by name at boot rather than silently matching nothing" do
          System.put_env("PHX_HOST", unquote(bad))

          assert_raise RuntimeError, ~r/PHX_HOST must be a host name/, fn ->
            endpoint(@env, :check_origin)
          end
        end
      end

      test "a specific PHX_BIND_IP is an address the browser types, so it is allowed" do
        System.put_env("PHX_BIND_IP", "192.168.1.5")

        assert admits?(endpoint(@env, :check_origin), "http://192.168.1.5:4000")
      end

      test "a specific IPv6 PHX_BIND_IP is allowed in bracketed form" do
        System.put_env("PHX_BIND_IP", "fe80::1")

        assert "//[fe80::1]" in endpoint(@env, :check_origin)
        assert admits?(endpoint(@env, :check_origin), "http://[fe80::1]:4000")
      end

      # Binding every interface says nothing about which name the browser
      # types; that is PHX_HOST's job, so the wildcard adds no origin at all.
      test "binding every interface adds no origin" do
        System.put_env("PHX_BIND_IP", "0.0.0.0")
        assert endpoint(@env, :check_origin) == @loopback_origins

        System.put_env("PHX_BIND_IP", "::")
        assert endpoint(@env, :check_origin) == @loopback_origins
      end

      test "is never false, which would admit every origin" do
        System.put_env("PHX_BIND_IP", "0.0.0.0")
        System.put_env("PHX_HOST", "doctrans.lan")

        assert is_list(endpoint(@env, :check_origin))
      end
    end
  end

  # The same names feed `DoctransWeb.Plugs.AllowedHost`, which refuses a plain
  # GET for any other `Host` (#260; the comment on the list in
  # `config/runtime.exs` tells the story). The assertions run the configured
  # list through the plug, so they are about which requests are answered.
  defp answers?(hosts, host) do
    Doctrans.TestEnv.put_env(:allowed_hosts, hosts)
    conn = %{conn(:get, "/") | host: host}

    {result, _log} = with_log(fn -> AllowedHost.call(conn, AllowedHost.init([])) end)

    not result.halted
  end

  @loopback_hosts ~w(localhost 127.0.0.1 [::1])

  for env <- [:dev, :prod] do
    describe "the host allowlist in #{env}" do
      @env env

      test "names the loopback hosts a local browser types, and nothing else" do
        assert allowed_hosts(@env) == @loopback_hosts
      end

      test "answers a local browser and refuses a foreign host" do
        hosts = allowed_hosts(@env)

        for host <- @loopback_hosts, do: assert(answers?(hosts, host))
        refute answers?(hosts, "attacker.example")
        refute answers?(hosts, "localhost.attacker.example")
      end

      test "is the list the socket origin allowlist is built from" do
        System.put_env("PHX_HOST", "Doctrans.LAN")
        System.put_env("PHX_BIND_IP", "fe80::1")

        hosts = allowed_hosts(@env)

        assert hosts == ~w(localhost 127.0.0.1 [::1] doctrans.lan [fe80::1])
        assert endpoint(@env, :check_origin) == Enum.map(hosts, &("//" <> &1))
      end

      test "PHX_HOST adds the name the browser types for a deployment, in lower case" do
        System.put_env("PHX_HOST", "Doctrans.LAN")

        hosts = allowed_hosts(@env)

        assert answers?(hosts, "doctrans.lan")
        refute answers?(hosts, "attacker.example")
      end

      test "a specific PHX_BIND_IP is an address the browser types, so it is answered" do
        System.put_env("PHX_BIND_IP", "192.168.1.5")

        assert answers?(allowed_hosts(@env), "192.168.1.5")
      end

      # Bandit reports an IPv6 request host in brackets, as the browser types it.
      test "a specific IPv6 PHX_BIND_IP is answered in bracketed form" do
        System.put_env("PHX_BIND_IP", "fe80::1")

        assert answers?(allowed_hosts(@env), "[fe80::1]")
      end

      test "binding every interface adds no host" do
        System.put_env("PHX_BIND_IP", "0.0.0.0")
        assert allowed_hosts(@env) == @loopback_hosts

        System.put_env("PHX_BIND_IP", "::")
        assert allowed_hosts(@env) == @loopback_hosts
      end
    end
  end

  # The advertised URL is what the app hands out as its own address, in
  # `Endpoint.url/0` and in the line logged at boot. Hardcoding https on 443 in
  # front of a listener that speaks plain HTTP on PORT names an address that
  # does not exist.
  describe "PHX_SCHEME" do
    test "the advertised URL defaults to http on the listening port" do
      System.put_env("PORT", "4321")

      assert endpoint(:url)[:scheme] == "http"
      assert endpoint(:url)[:port] == 4321
    end

    test "https advertises 443, for a TLS proxy terminating in front" do
      System.put_env(%{"PHX_SCHEME" => "https", "PORT" => "4321"})

      assert endpoint(:url)[:scheme] == "https"
      assert endpoint(:url)[:port] == 443
      # The listener itself still speaks plain HTTP behind the proxy.
      assert endpoint(:http)[:port] == 4321
    end

    test "a scheme that is neither http nor https is rejected by name" do
      System.put_env("PHX_SCHEME", "ftp")

      assert_raise RuntimeError, ~r/PHX_SCHEME.*ftp/s, fn -> endpoint(:url) end
    end
  end
end
