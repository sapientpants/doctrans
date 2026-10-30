defmodule Doctrans.Processing.Worker do
  @moduledoc """
  Runs the startup recovery pass.

  The GenServer owns one piece of work: shortly after boot it walks
  `StartupRecovery` one batch at a time, so a large backlog of interrupted
  documents is re-queued in the background rather than as a single burst.
  Enqueueing lives on the job modules (`DocumentExtractionJob.enqueue_document/2`,
  `LlmProcessingJob.enqueue_page/2`, `EmbeddingJob.enqueue_page/1`) and job
  cancellation on `Cancellation`.

  ## Configuration

      config :doctrans, Doctrans.Processing.Worker,
        startup_recovery: true,
        startup_delay_ms: 5_000,
        batch_interval_ms: 1_000

  Set `startup_recovery: false` to skip the pass scheduled at boot. The worker
  still starts; only the boot-time schedule is skipped. `recover_now/1` runs the
  same pass on demand regardless of the setting.

  The same three keys are accepted as start options, which take precedence, so a
  test can start an instance on either side of the switch without a global
  override.
  """

  use GenServer
  require Logger

  alias Doctrans.Processing.StartupRecovery

  @default_startup_recovery true
  # Late enough that the rest of the supervision tree is up before the first
  # query, and spaced so recovery of a large backlog stays in the background
  # rather than arriving as one burst.
  @default_startup_delay_ms 5_000
  @default_batch_interval_ms 1_000
  # `recover_now/1` walks every batch back to back, so its ceiling is the size of
  # the backlog rather than the schedule above.
  @recover_now_timeout :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs the startup recovery pass now and returns when it has finished.

  Works even when the boot-time pass is disabled (`startup_recovery: false` only
  skips the schedule in `init/1`). Unlike that pass, this one walks every batch
  without pausing between them, so the reply is the signal that recovery is
  complete rather than merely started.
  """
  @spec recover_now(GenServer.server()) :: :ok
  def recover_now(server \\ __MODULE__) do
    GenServer.call(server, :recover_now, @recover_now_timeout)
  end

  @impl true
  def init(opts) do
    config = config(opts)

    if config[:startup_recovery] do
      # Schedule recovery of incomplete documents after init completes
      Process.send_after(self(), :recover_incomplete_documents, config[:startup_delay_ms])

      Logger.info(
        "Processing.Worker started, recovering incomplete work in " <>
          "#{config[:startup_delay_ms]}ms"
      )
    else
      Logger.info("Processing.Worker startup recovery is disabled")
    end

    {:ok, %{batch_interval_ms: config[:batch_interval_ms]}}
  end

  # Start options win over the application environment, so a test can start an
  # instance of its own on either side of the switch without a global override.
  defp config(opts) do
    app_config = Application.get_env(:doctrans, __MODULE__, [])

    for {key, default} <- [
          startup_recovery: @default_startup_recovery,
          startup_delay_ms: @default_startup_delay_ms,
          batch_interval_ms: @default_batch_interval_ms
        ] do
      {key, Keyword.get(opts, key, Keyword.get(app_config, key, default))}
    end
  end

  @impl true
  def handle_call(:recover_now, _from, state) do
    {:reply, run_pass({:documents, nil}), state}
  end

  defp run_pass(:done), do: :ok
  defp run_pass(cursor), do: cursor |> StartupRecovery.run_batch() |> run_pass()

  @impl true
  def handle_info(:recover_incomplete_documents, state) do
    send(self(), {:recover_batch, {:documents, nil}})
    {:noreply, state}
  end

  def handle_info({:recover_batch, cursor}, state) do
    _ =
      case StartupRecovery.run_batch(cursor) do
        :done -> :ok
        next -> Process.send_after(self(), {:recover_batch, next}, state.batch_interval_ms)
      end

    {:noreply, state}
  end

  # Late replies and monitors from work this process does not own land here.
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
