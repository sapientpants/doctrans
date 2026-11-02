defmodule Doctrans.Resilience.FuseProbe do
  @moduledoc """
  Test helpers for the `:fuse` circuit breakers.

  Shared by the request-layer suites of the chat and embedding clients, which
  both need to blow a fuse directly and to see every failure counted against
  one.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Doctrans.Resilience.CircuitBreaker

  @doc """
  Blows `fuse_name` directly.

  `:embedding_api` opens after 3 failures in 30 s and `:openai_api` after 5 in
  60 s, so six melts cover both.
  """
  @spec blow(atom()) :: :ok
  def blow(fuse_name) do
    for _ <- 1..6, do: :fuse.melt(fuse_name)
    assert CircuitBreaker.status(fuse_name) == :blown
    :ok
  end

  @doc "Forwards every circuit-breaker failure to the calling test as `{:circuit_failure, fuse}`."
  @spec watch_failures() :: :ok
  def watch_failures do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:doctrans, :circuit_breaker, :failure],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:circuit_failure, metadata.fuse_name})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
