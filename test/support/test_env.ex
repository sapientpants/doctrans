defmodule Doctrans.TestEnv do
  @moduledoc """
  Scopes VM-global state -- an `Application` env override, the circuit
  breakers -- to the lifetime of one test.

  Changing a setting in the application environment is how this suite drives
  the code that reads configuration (collaborator modules are Mox mocks and need
  no override; see `Doctrans.Mocks`), and every such change has to be undone or
  it leaks into the next test. This restores the previous value — including the
  absence of one — when the test exits.

  It scopes the override in *time*, not in space: `Application.put_env/3` is
  VM-global, so while the override stands it is the value every process sees,
  not just this one. That makes it safe only in an `async: false` test, and
  `put_env/2` raises in an async one rather than silently handing a concurrent
  test the wrong collaborator. The check reads a flag recorded per test by
  `Doctrans.DataCase.setup_sandbox/1` or `Doctrans.EnvCase`.

  The `:fuse` circuit breakers are global in the same way, and `reset_fuses/0`
  applies the same rule to them.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Doctrans.Resilience.CircuitBreaker

  @async_key :doctrans_test_env_async

  @doc """
  Records whether the running test is `async: true`.

  Called once per test from `Doctrans.DataCase.setup_sandbox/1`; the flag lives
  in the test process's dictionary, so it cannot outlive or escape the test.
  """
  def record_async(tags), do: Process.put(@async_key, tags[:async] == true)

  @doc """
  Whether the running test registered itself as `async: true`.

  `nil` when no case template registered this process at all, which is what
  `put_env/2` refuses on.
  """
  def async?, do: Process.get(@async_key)

  @doc """
  Sets `:doctrans`'s `key` for the running test and restores it afterwards.

  A test may override the same key more than once: `on_exit` callbacks run in
  reverse registration order, so the restores unwind to the value that stood
  before the first override.
  """
  def put_env(key, value) do
    override(key, "put_env/2", fn -> Application.put_env(:doctrans, key, value) end)
  end

  @doc """
  Removes `:doctrans`'s `key` for the running test and restores it afterwards.

  For a test of what the code does when a setting is absent: `put_env(key, nil)`
  is not the same thing, because `Application.get_env/3` returns the `nil` it
  finds rather than the default.
  """
  def delete_env(key) do
    override(key, "delete_env/1", fn -> Application.delete_env(:doctrans, key) end)
  end

  @doc """
  Resets every circuit breaker for the running test, and again when it exits.

  A fuse is VM-global state like the application env, and nothing undoes a melt
  on its own: the `:standard` strategy counts melts over a window of up to a
  minute, and a blown fuse stays blown until its refresh timer fires. So a test
  that fails real requests through `Doctrans.Processing.OpenAI` -- or blows a
  fuse on purpose -- leaves the next test's calls asked against that history,
  and a blown `:openai_api` turns `OpenAI.list_models/0` into
  `{:error, :circuit_open}` without a request. Call this from the `setup` of a
  test whose outcome depends on a closed circuit.

  Like `put_env/2` it is only safe in an `async: false` test, and raises in an
  async one: the reset would land on whatever a concurrent test was asserting.
  """
  def reset_fuses do
    refuse_async!("reset_fuses/0", "the circuit breakers")
    reset_all_fuses()
    on_exit(&reset_all_fuses/0)
  end

  defp reset_all_fuses do
    for name <- CircuitBreaker.fuse_names(), do: CircuitBreaker.reset(name)
    :ok
  end

  defp override(key, fun, change) do
    refuse_async!(fun, "#{inspect(key)}")

    previous = Application.fetch_env(:doctrans, key)
    change.()

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(:doctrans, key, previous_value)
        :error -> Application.delete_env(:doctrans, key)
      end
    end)
  end

  defp refuse_async!(fun, subject) do
    registered = async?()

    if is_nil(registered) do
      raise ArgumentError,
            "use Doctrans.EnvCase, DataCase or ConnCase before calling " <>
              "#{inspect(__MODULE__)}.#{fun}"
    end

    if registered do
      raise ArgumentError, """
      #{inspect(__MODULE__)}.#{fun} was called from an async test.

      That state is global. Changing #{subject} here would apply to every test \
      running concurrently, not just this one, and would be restored out from \
      under them when this test exits.

      Move the test to `async: false`, or drive the collaborator without \
      touching global state.
      """
    end
  end
end
