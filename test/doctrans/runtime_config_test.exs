defmodule Doctrans.RuntimeConfigTest do
  # Reads `config/runtime.exs` directly: `mix test` never evaluates the storage
  # root block it defines, so the operator-facing variable is otherwise untested.
  use ExUnit.Case, async: false

  @env_keys ~w(DOCTRANS_DATA_DIR DATABASE_URL SECRET_KEY_BASE DOCTRANS_ENV_FILE
               PHX_BIND_IP PHX_SCHEME PORT)

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

    Enum.each(~w(DOCTRANS_DATA_DIR PHX_BIND_IP PHX_SCHEME PORT), &System.delete_env/1)
    :ok
  end

  defp read_config(env) do
    Path.expand("../../config/runtime.exs", __DIR__)
    |> Config.Reader.read!(env: env)
  end

  defp upload_dir(env), do: get_in(read_config(env), [:doctrans, :uploads, :upload_dir])

  defp endpoint(key), do: get_in(read_config(:prod), [:doctrans, DoctransWeb.Endpoint, key])

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
  describe "PHX_BIND_IP" do
    test "defaults to the loopback address as a tuple, not a string" do
      assert endpoint(:http)[:ip] == {127, 0, 0, 1}
    end

    test "parses an explicit IPv4 literal" do
      System.put_env("PHX_BIND_IP", "0.0.0.0")

      assert endpoint(:http)[:ip] == {0, 0, 0, 0}
    end

    test "parses an IPv6 literal" do
      System.put_env("PHX_BIND_IP", "::1")

      assert endpoint(:http)[:ip] == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "a value that is not an address literal is rejected by name" do
      System.put_env("PHX_BIND_IP", "localhost")

      assert_raise RuntimeError, ~r/PHX_BIND_IP.*localhost/s, fn -> endpoint(:http) end
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
