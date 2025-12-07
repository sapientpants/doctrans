defmodule Doctrans.Documents.SweeperWorker do
  @moduledoc """
  Scheduled worker that periodically cleans up orphaned document files.

  This GenServer runs on a configurable interval and removes:
  - Orphaned directories (filesystem directories without database records)
  - Stale documents (documents stuck in transient states for too long)

  ## Configuration

  Configure in `config/config.exs`:

      config :doctrans, Doctrans.Documents.SweeperWorker,
        enabled: true,
        interval_hours: 6,
        stale_document_hours: 24,
        stale_statuses: ["uploading", "extracting"]

  Set `enabled: false` to disable the sweeper entirely.
  """

  use GenServer

  require Logger

  alias Doctrans.Documents.Sweeper

  @default_interval_hours 6
  @default_stale_hours 24
  @default_stale_statuses ["uploading", "extracting"]

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
      stale_hours: config[:stale_document_hours],
      stale_statuses: config[:stale_statuses],
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
      stale_hours: state.stale_hours,
      stale_statuses: state.stale_statuses,
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

    opts = [
      max_age_hours: state.stale_hours,
      statuses: state.stale_statuses
    ]

    result = Sweeper.sweep_all(opts)

    log_results(result)

    %{state | last_sweep: DateTime.utc_now(), sweep_count: state.sweep_count + 1}
  end

  defp log_results(result) do
    case result do
      %{orphaned_directories: {:ok, orphaned}, stale_documents: {:ok, stale}} ->
        Logger.info(
          "Sweep complete: #{orphaned} orphaned directories, #{stale} stale documents removed"
        )

      _ ->
        Logger.warning("Sweep completed with some errors: #{inspect(result)}")
    end
  end

  defp get_config do
    config = Application.get_env(:doctrans, __MODULE__, [])

    [
      enabled: Keyword.get(config, :enabled, true),
      interval_hours: Keyword.get(config, :interval_hours, @default_interval_hours),
      stale_document_hours: Keyword.get(config, :stale_document_hours, @default_stale_hours),
      stale_statuses: Keyword.get(config, :stale_statuses, @default_stale_statuses)
    ]
  end
end
