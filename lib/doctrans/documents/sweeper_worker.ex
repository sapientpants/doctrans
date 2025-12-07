defmodule Doctrans.Documents.SweeperWorker do
  @moduledoc """
  Scheduled worker that periodically cleans up orphaned document directories.

  A directory is considered orphaned when it's older than the configured
  grace period and has no matching document in the database.

  ## Configuration

  Configure in `config/config.exs`:

      config :doctrans, Doctrans.Documents.SweeperWorker,
        enabled: true,
        interval_hours: 6,
        grace_period_hours: 24

  Set `enabled: false` to disable the sweeper entirely.
  """

  use GenServer

  require Logger

  alias Doctrans.Documents.Sweeper

  @default_interval_hours 6
  @default_grace_period_hours 24

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate sweep. Useful for testing or manual intervention.
  """
  def sweep_now do
    GenServer.cast(__MODULE__, :sweep_now)
  end

  @doc """
  Returns the current configuration and status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    config = get_config()

    state = %{
      enabled: config[:enabled],
      interval_ms: config[:interval_hours] * 60 * 60 * 1000,
      grace_period_hours: config[:grace_period_hours],
      last_sweep: nil,
      sweep_count: 0
    }

    if state.enabled do
      # Schedule first sweep after a short delay to let the app fully start
      Process.send_after(self(), :sweep, :timer.minutes(1))

      Logger.info(
        "SweeperWorker started, first sweep in 1 minute, then every #{config[:interval_hours]} hours"
      )
    else
      Logger.info("SweeperWorker is disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_cast(:sweep_now, state) do
    {:noreply, do_sweep(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      interval_hours: div(state.interval_ms, 60 * 60 * 1000),
      grace_period_hours: state.grace_period_hours,
      last_sweep: state.last_sweep,
      sweep_count: state.sweep_count
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    new_state = do_sweep(state)

    # Schedule next sweep
    if state.enabled do
      Process.send_after(self(), :sweep, state.interval_ms)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_sweep(state) do
    Logger.info("Starting scheduled document sweep...")

    {:ok, count} = Sweeper.sweep(grace_period_hours: state.grace_period_hours)
    Logger.info("Sweep complete: #{count} orphaned directories removed")

    %{state | last_sweep: DateTime.utc_now(), sweep_count: state.sweep_count + 1}
  end

  defp get_config do
    config = Application.get_env(:doctrans, __MODULE__, [])

    [
      enabled: Keyword.get(config, :enabled, true),
      interval_hours: Keyword.get(config, :interval_hours, @default_interval_hours),
      grace_period_hours: Keyword.get(config, :grace_period_hours, @default_grace_period_hours)
    ]
  end
end
