defmodule Doctrans.TestEnv do
  @moduledoc """
  Scopes an `Application` env override to the lifetime of one test.

  Swapping a module or a flag in the application environment is how this suite
  drives configurable collaborators, and every such swap has to be undone or it
  leaks into the next test. This restores the previous value — including the
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
  Sets `:doctrans`'s `key` for the running test and restores it afterwards.
  """
  def put_env(key, value) do
    registered = Process.get(@async_key)

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
    Application.put_env(:doctrans, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(:doctrans, key, previous_value)
        :error -> Application.delete_env(:doctrans, key)
      end
    end)
  end
end
