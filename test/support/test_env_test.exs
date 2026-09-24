defmodule Doctrans.TestEnvTest do
  use Doctrans.EnvCase, async: true

  alias Doctrans.TestEnv

  test "an async case cannot change global configuration" do
    previous = Application.fetch_env(:doctrans, :test_env_guard_probe)

    assert_raise ArgumentError, ~r/called from an async test/, fn ->
      TestEnv.put_env(:test_env_guard_probe, :unexpected)
    end

    assert Application.fetch_env(:doctrans, :test_env_guard_probe) == previous
  end

  test "a process with no case registration cannot change global configuration" do
    task =
      Task.async(fn ->
        assert_raise ArgumentError, ~r/use Doctrans.EnvCase/, fn ->
          TestEnv.put_env(:test_env_guard_probe, :unexpected)
        end
      end)

    Task.await(task)
    refute Application.get_env(:doctrans, :test_env_guard_probe)
  end
end
