defmodule Doctrans.TestEnvFusesTest do
  # Sync: the test blows a shared fuse on purpose; `reset_fuses/0` is what
  # keeps that from reaching the next test, and is what is under test here.
  use Doctrans.EnvCase, async: false

  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.TestEnv

  @moduletag :capture_log

  test "closes every blown fuse for the test, and again when the test exits" do
    for name <- CircuitBreaker.fuse_names(), do: blow(name)

    # Registered before `reset_fuses/0` registers its own exit callback, so it
    # runs after that one and sees what the next test would.
    on_exit(fn ->
      assert CircuitBreaker.status_all() ==
               Map.new(CircuitBreaker.fuse_names(), &{&1, :ok})
    end)

    TestEnv.reset_fuses()
    assert CircuitBreaker.status_all() == Map.new(CircuitBreaker.fuse_names(), &{&1, :ok})

    # Left blown on purpose: only the exit callback above can close it.
    blow(:openai_api)
    assert CircuitBreaker.status(:openai_api) == :blown
  end

  defp blow(name) do
    for _ <- 1..6, do: CircuitBreaker.melt(name)
    :blown = CircuitBreaker.status(name)
  end
end
