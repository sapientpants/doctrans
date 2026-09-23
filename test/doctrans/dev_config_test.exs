defmodule Doctrans.DevConfigTest do
  # Reads `config/dev.exs` directly: `mix test` never evaluates it, so the
  # interface the development endpoint listens on — the one setting that decides
  # whether an app with no authentication is reachable from the LAN — is
  # otherwise untested.
  use ExUnit.Case, async: false

  @env_keys ~w(PHX_BIND_IP DATABASE_HOST PORT)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    :ok
  end

  defp read_config do
    Path.expand("../../config/dev.exs", __DIR__)
    |> Config.Reader.read!(env: :dev)
  end

  defp endpoint(key), do: get_in(read_config(), [:doctrans, DoctransWeb.Endpoint, key])

  # Bandit types `:ip` as `:inet.socket_address()` and hands it to
  # `:gen_tcp.listen/2`, which exits with :badarg on a string. A textual address
  # here is not a cosmetic problem: the endpoint never starts.
  describe "PHX_BIND_IP" do
    test "defaults to the loopback address as a tuple, not a string" do
      assert endpoint(:http)[:ip] == {127, 0, 0, 1}
    end

    # The regression this file exists for. The binding used to be derived from
    # DATABASE_HOST, so moving development's Postgres to another host silently
    # published an unauthenticated app on every interface. Before that change
    # this assertion read {0, 0, 0, 0} and this test failed.
    test "a remote DATABASE_HOST does not widen the binding" do
      System.put_env("DATABASE_HOST", "postgres.internal")

      assert endpoint(:http)[:ip] == {127, 0, 0, 1}
      # The database host itself is still honoured; only the binding ignores it.
      assert get_in(read_config(), [:doctrans, Doctrans.Repo, :hostname]) ==
               "postgres.internal"
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

    # `System.get_env/1 || default` treats "" as a value, so an explicitly empty
    # setting does not fall back to loopback — it fails to parse. Refusing to
    # start is the right answer either way, and the README says so; this pins it
    # rather than leaving the documented behaviour to the shape of an `||`.
    test "an explicitly empty value is rejected rather than falling back" do
      System.put_env("PHX_BIND_IP", "")

      assert_raise RuntimeError, ~r/PHX_BIND_IP must be an IPv4 or IPv6 address literal/, fn ->
        endpoint(:http)
      end
    end
  end

  test "PORT still chooses the listening port" do
    System.put_env("PORT", "4321")

    assert endpoint(:http)[:port] == 4321
  end
end
