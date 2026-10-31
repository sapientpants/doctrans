defmodule Doctrans.TestEnv do
  @moduledoc """
  Scopes an `Application` env override to the lifetime of one test.

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
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

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
    override(key, fn -> Application.put_env(:doctrans, key, value) end)
  end

  @doc """
  Removes `:doctrans`'s `key` for the running test and restores it afterwards.

  For a test of what the code does when a setting is absent: `put_env(key, nil)`
  is not the same thing, because `Application.get_env/3` returns the `nil` it
  finds rather than the default.
  """
  def delete_env(key) do
    override(key, fn -> Application.delete_env(:doctrans, key) end)
  end

  defp override(key, change) do
    registered = async?()

    if is_nil(registered) do
      raise ArgumentError,
            "use Doctrans.EnvCase, DataCase or ConnCase before overriding application env"
    end

    if registered do
      raise ArgumentError, """
      #{inspect(__MODULE__)}.put_env/2 was called from an async test.

      Application env is global. Overriding #{inspect(key)} here would apply to \
      every test running concurrently, not just this one, and would be restored \
      out from under them when this test exits.

      Move the test to `async: false`, or drive the collaborator without \
      touching application env.
      """
    end

    previous = Application.fetch_env(:doctrans, key)
    change.()

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(:doctrans, key, previous_value)
        :error -> Application.delete_env(:doctrans, key)
      end
    end)
  end
end
