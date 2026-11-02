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

  The same three keys are accepted as start options, which take precedence, so
  a test can start an instance of its own without a global override.
  """

  use GenServer

  require Logger

  alias Doctrans.Documents.Sweeper
  alias Doctrans.Errors

  @default_interval_hours 6
  @default_grace_period_hours 24

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate sweep asynchronously.

  Returns immediately without waiting for completion. Use `status/0` to check
  when the last sweep occurred. Works even when the worker is disabled
  (enabled: false only disables the scheduled sweeps).
  """
  @spec sweep_now() :: :ok
  def sweep_now do
    GenServer.cast(__MODULE__, :sweep_now)
  end

  @doc """
  Returns the current configuration and status.

  `last_result` is the last sweep's `Doctrans.Documents.Sweeper.sweep/1`
  result, so an orphan the sweeper could not remove is reported here as
  `{:error, {:sweep_incomplete, deleted: count, failed: paths}}`. A sweep that
  raised is reported as `{:error, reason}` too, with the database failure in the
  `{:database_error, reason: error}` shape the rest of the application uses.
  """
  @spec status() :: %{
          enabled: boolean(),
          interval_hours: non_neg_integer(),
          grace_period_hours: pos_integer(),
          last_sweep: DateTime.t() | nil,
          sweep_count: non_neg_integer(),
          last_result: {:ok, non_neg_integer()} | {:error, Errors.reason()} | nil
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config = config(opts)

    state = %{
      enabled: config[:enabled],
      interval_ms: config[:interval_hours] * 60 * 60 * 1000,
      grace_period_hours: config[:grace_period_hours],
      last_sweep: nil,
      sweep_count: 0,
      last_result: nil
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
      sweep_count: state.sweep_count,
      last_result: state.last_result
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    new_state = do_sweep(state)

    # Schedule next sweep
    _ref =
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

    result =
      state.grace_period_hours
      |> run_sweep()
      |> report_sweep()

    %{
      state
      | last_sweep: DateTime.utc_now(),
        sweep_count: state.sweep_count + 1,
        last_result: result
    }
  end

  defp run_sweep(grace_period_hours) do
    Sweeper.sweep(grace_period_hours: grace_period_hours)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:database_error, [reason: error]}}

    error ->
      {:error, Errors.normalize(error)}
  end

  defp report_sweep({:ok, count} = result) do
    Logger.info("Sweep complete: #{count} orphaned directories removed")
    :telemetry.execute([:doctrans, :sweeper, :completed], %{count: count}, %{})
    result
  end

  defp report_sweep({:error, reason} = result) do
    Logger.error("Sweep failed: #{inspect(reason)}")
    :telemetry.execute([:doctrans, :sweeper, :failed], %{count: 1}, %{error: reason})
    result
  end

  # Start options win over the application environment, so a test can start an
  # instance of its own without a global override.
  defp config(opts) do
    app_config = Application.get_env(:doctrans, __MODULE__, [])

    for {key, default} <- [
          enabled: true,
          interval_hours: @default_interval_hours,
          grace_period_hours: @default_grace_period_hours
        ] do
      {key, Keyword.get(opts, key, Keyword.get(app_config, key, default))}
    end
  end
end
