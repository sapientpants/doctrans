defmodule Doctrans.Resilience.HealthCheckWorker do
  @moduledoc """
  Periodic health check worker.

  Runs health checks at configurable intervals and emits telemetry events.
  Can automatically reset circuit breakers when services recover.

  ## Configuration

      config :doctrans, Doctrans.Resilience.HealthCheckWorker,
        enabled: true,
        interval_ms: 60_000,
        auto_reset_circuits: true

  ## Telemetry Events

  - `[:doctrans, :health_check, :completed]` - Emitted for each check
  - `[:doctrans, :health_check, :all_completed]` - Emitted after all checks

  """

  use GenServer
  require Logger

  alias Doctrans.Resilience.{CircuitBreaker, HealthCheck}

  @default_interval_ms 60_000
  @default_auto_reset true

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current health check status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Triggers an immediate health check.
  """
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config[:enabled],
      interval_ms: config[:interval_ms],
      auto_reset_circuits: config[:auto_reset_circuits],
      last_check: nil,
      last_results: nil,
      check_count: 0
    }

    if state.enabled do
      # Schedule first check after a short delay
      Process.send_after(self(), :check, :timer.seconds(10))
      Logger.info("HealthCheckWorker started, checking every #{state.interval_ms}ms")
    else
      Logger.info("HealthCheckWorker is disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      interval_ms: state.interval_ms,
      auto_reset_circuits: state.auto_reset_circuits,
      last_check: state.last_check,
      last_results: state.last_results,
      check_count: state.check_count,
      circuit_breakers: CircuitBreaker.status_all()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:check_now, %{enabled: false} = state) do
    # Skip check when disabled
    {:noreply, state}
  end

  def handle_cast(:check_now, state) do
    {:noreply, do_check(state)}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = do_check(state)

    # Schedule next check
    if state.enabled do
      Process.send_after(self(), :check, state.interval_ms)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_check(state) do
    Logger.debug("Running health checks...")
    results = HealthCheck.check_all()

    # Log any failures
    Enum.each(results, fn
      {name, {:error, reason}} ->
        Logger.warning("Health check failed: #{name} - #{inspect(reason)}")

      {name, :ok} ->
        Logger.debug("Health check passed: #{name}")

      {name, {:ok, _}} ->
        Logger.debug("Health check passed: #{name}")
    end)

    # Auto-reset circuit breakers if services recovered
    if state.auto_reset_circuits do
      maybe_reset_circuits(results, state.last_results)
    end

    # Emit summary telemetry
    healthy_count = Enum.count(results, fn {_, r} -> r == :ok or match?({:ok, _}, r) end)

    :telemetry.execute(
      [:doctrans, :health_check, :all_completed],
      %{
        total: map_size(results),
        healthy: healthy_count,
        unhealthy: map_size(results) - healthy_count
      },
      %{}
    )

    %{
      state
      | last_check: DateTime.utc_now(),
        last_results: results,
        check_count: state.check_count + 1
    }
  end

  defp maybe_reset_circuits(current_results, previous_results) when is_map(previous_results) do
    # Check if Ollama recovered (was failing, now healthy)
    ollama_was_failing =
      case previous_results[:ollama] do
        {:error, _} -> true
        _ -> false
      end

    ollama_now_healthy =
      case current_results[:ollama] do
        {:ok, _} -> true
        _ -> false
      end

    if ollama_was_failing and ollama_now_healthy do
      Logger.info("Ollama recovered, resetting circuit breakers")
      CircuitBreaker.reset(:ollama_api)
      CircuitBreaker.reset(:embedding_api)
    end
  end

  defp maybe_reset_circuits(_current, _previous), do: :ok

  defp get_config do
    config = Application.get_env(:doctrans, __MODULE__, [])

    [
      enabled: Keyword.get(config, :enabled, true),
      interval_ms: Keyword.get(config, :interval_ms, @default_interval_ms),
      auto_reset_circuits: Keyword.get(config, :auto_reset_circuits, @default_auto_reset)
    ]
  end
end
