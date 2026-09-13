defmodule Doctrans.TestEnv do
  @moduledoc """
  Scopes an `Application` env override to one test.

  Swapping a module or a flag in the application environment is how this suite
  drives configurable collaborators, and every such swap has to be undone or it
  leaks into the next test. This restores the previous value — including the
  absence of one — when the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets `:doctrans`'s `key` for the running test and restores it afterwards.
  """
  def put_env(key, value) do
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
