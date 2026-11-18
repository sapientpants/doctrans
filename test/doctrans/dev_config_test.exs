defmodule Doctrans.DevConfigTest do
  # Reads `config/dev.exs` directly: `mix test` never evaluates it. The
  # development listener itself is configured in `config/runtime.exs` and tested
  # in `Doctrans.RuntimeConfigTest`; what this file pins is that `dev.exs` has
  # not grown a listener of its own again.
  #
  # `async: false`: the OS environment it sets is shared by the whole VM.
  use Doctrans.EnvCase, async: false

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

  defp endpoint, do: get_in(read_config(), [:doctrans, DoctransWeb.Endpoint])

  # The regression this file exists for. The binding used to be derived from
  # DATABASE_HOST here, so moving development's Postgres to another host
  # silently published an unauthenticated app on every interface. The listener
  # now lives in `config/runtime.exs`, where the parse is stated once for every
  # environment; `dev.exs` must not quietly reintroduce one that the runtime
  # file would then merge over, or that reads a variable it should not.
  test "configures no listener of its own, so the runtime one is the only one" do
    System.put_env("DATABASE_HOST", "postgres.internal")
    System.put_env("PHX_BIND_IP", "0.0.0.0")
    System.put_env("PORT", "4321")

    refute Keyword.has_key?(endpoint(), :http)
    refute Keyword.has_key?(endpoint(), :https)
  end

  # `check_origin: false` lived here (#259; see the allowlist's comment in
  # `config/runtime.exs`). That allowlist is configured for every environment
  # that serves; `dev.exs` must not quietly override it with a setting of its own.
  test "does not configure the socket origin check, so the runtime allowlist is the only one" do
    refute Keyword.has_key?(endpoint(), :check_origin)
  end

  # The host allowlist is built beside the origin allowlist in
  # `config/runtime.exs` (#260); `dev.exs` must not quietly override it either.
  test "does not configure the host allowlist, so the runtime one is the only one" do
    refute Keyword.has_key?(Keyword.fetch!(read_config(), :doctrans), :allowed_hosts)
  end

  # The browser console must not get a copy of the development log; the reason
  # is beside the flag in `config/dev.exs` (#265). Asserted `false` rather than
  # absent, so the file states the choice.
  test "does not stream the server log to the browser console" do
    assert get_in(endpoint(), [:live_reload, :web_console_logger]) == false
  end

  # With `debug_errors` on, `Plug.Debugger` is compiled into the endpoint and
  # applies any MFA POSTed to `/__plug__/debugger/action` under a valid
  # signature, ahead of every plug (#333). A request-level test would pass
  # vacuously, since the test environment never compiles the debugger in, so
  # the file itself is what is pinned. Asserted `false` rather than absent, so
  # the file states the choice.
  test "does not compile the error debugger into the endpoint" do
    assert Keyword.fetch!(endpoint(), :debug_errors) == false
  end

  # The other half of #333: a literal key in a public repository signs for
  # anyone who reads it. `config/runtime.exs` resolves both per machine.
  test "carries no literal secret_key_base or LiveView signing salt" do
    refute Keyword.has_key?(endpoint(), :secret_key_base)
    refute Keyword.has_key?(Keyword.get(endpoint(), :live_view, []), :signing_salt)
  end

  test "DATABASE_HOST still selects the development database host" do
    System.put_env("DATABASE_HOST", "postgres.internal")

    assert get_in(read_config(), [:doctrans, Doctrans.Repo, :hostname]) == "postgres.internal"
  end
end
