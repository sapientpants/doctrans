defmodule Doctrans.Resilience.HealthCheckWorkerTest do
  @moduledoc """
  Drives the worker's own check cycle.

  `config/test.exs` disables the worker the application starts, because a
  worker left enabled would run real checks on its interval for the whole
  suite. These tests therefore start their own instance instead: the worker
  prefers its start options to the application environment, so each test hands
  its settings to the instance it starts, unnamed, next to the disabled one,
  and nothing global changes. The OpenAI probe is forwarded from
  `OpenAIMock` to the real client, which reaches a local Bypass server, and the
  database probe runs on the shared sandbox connection, so a cycle is driven
  end to end without touching the network.
  """

  use Doctrans.DataCase, async: false

  alias Doctrans.Processing.{OpenAI, OpenAIBypass, OpenAIMock}
  alias Doctrans.Resilience.HealthCheckWorker
  alias Doctrans.TestEnv
  alias Ecto.Adapters.SQL.Sandbox

  @all_completed [:doctrans, :health_check, :all_completed]

  setup do
    Mox.stub_with(OpenAIMock, OpenAI)
    TestEnv.reset_fuses()

    bypass = Bypass.open()

    TestEnv.merge_env(:openai,
      base_url: "http://localhost:#{bypass.port}",
      api_key: "sk-test-123"
    )

    %{bypass: bypass}
  end

  describe "init/1" do
    test "reports its configuration before the first check has run" do
      pid = start_worker!(enabled: true, interval_ms: 30_000)

      assert GenServer.call(pid, :status) == %{
               enabled: true,
               interval_ms: 30_000,
               last_check: nil,
               last_results: nil,
               check_count: 0,
               circuit_breakers: %{openai_api: :ok, embedding_api: :ok}
             }
    end

    test "falls back to the module defaults when nothing is configured" do
      # `config/test.exs` disables the application's worker; clear that so the
      # module defaults are what is left.
      TestEnv.put_env(HealthCheckWorker, [])
      pid = start_worker!([])

      status = GenServer.call(pid, :status)

      assert status.enabled
      assert status.interval_ms == 60_000
    end

    test "start options win over the application environment" do
      TestEnv.put_env(HealthCheckWorker, enabled: true, interval_ms: 5_000)

      pid = start_worker!(enabled: false)

      # The interval is the one key the start options leave to the environment.
      assert %{enabled: false, interval_ms: 5_000} = GenServer.call(pid, :status)
    end

    test "a disabled worker ignores a check request", %{bypass: bypass} do
      test_pid = self()
      Bypass.stub(bypass, "GET", "/v1/models", &models(&1, test_pid, []))

      pid = start_worker!(enabled: false, interval_ms: 60_000)
      GenServer.cast(pid, :check_now)

      status = GenServer.call(pid, :status)

      assert status.check_count == 0
      assert status.last_check == nil
      assert status.last_results == nil
      refute_received :http_request
    end
  end

  describe "check cycle" do
    test "records the results, the time and the count of each check", %{bypass: bypass} do
      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, ["gpt-4o-mini"]))

      pid = start_worker!(enabled: true, interval_ms: 60_000)
      GenServer.cast(pid, :check_now)

      first = GenServer.call(pid, :status)

      assert first.check_count == 1

      assert first.last_results == %{
               openai: {:ok, %{available: true, models: ["gpt-4o-mini"], circuit: :ok}},
               database: :ok,
               filesystem: :ok
             }

      assert %DateTime{} = first.last_check
      assert_received :http_request

      GenServer.cast(pid, :check_now)
      second = GenServer.call(pid, :status)

      assert second.check_count == 2
      assert DateTime.compare(second.last_check, first.last_check) in [:gt, :eq]
    end

    test "keeps the failing verdict of an unhealthy dependency", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", &Plug.Conn.resp(&1, 401, "unauthorized"))

      pid = start_worker!(enabled: true, interval_ms: 60_000)
      GenServer.cast(pid, :check_now)

      status = GenServer.call(pid, :status)

      assert status.last_results.openai == {:error, {:http_error, [status: 401]}}
      assert status.last_results.database == :ok
      assert status.check_count == 1
    end

    test "emits a summary counting the healthy dependencies", %{bypass: bypass} do
      attach_summary()
      Bypass.expect(bypass, "GET", "/v1/models", &Plug.Conn.resp(&1, 401, "unauthorized"))

      pid = start_worker!(enabled: true, interval_ms: 60_000)
      GenServer.cast(pid, :check_now)

      assert_receive {:summary, %{total: 3, healthy: 2, unhealthy: 1}}
    end

    test "counts every dependency as healthy when all of them pass", %{bypass: bypass} do
      attach_summary()
      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, []))

      pid = start_worker!(enabled: true, interval_ms: 60_000)
      GenServer.cast(pid, :check_now)

      assert_receive {:summary, %{total: 3, healthy: 3, unhealthy: 0}}
    end

    test "schedules the next check after running the scheduled one", %{bypass: bypass} do
      attach_summary()
      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, []))

      # A short interval keeps the reschedule observable: the timer the worker
      # sets for itself has to deliver a second `:check` without further help.
      pid = start_worker!(enabled: true, interval_ms: 25)
      send(pid, :check)

      assert_receive {:summary, %{total: 3}}, 1_000
      assert_receive {:summary, %{total: 3}}, 1_000
      assert GenServer.call(pid, :status).check_count >= 2

      # Stop before the sandbox owner goes away, so no check outlives the test.
      :ok = stop_supervised(:health_check_worker)
    end

    test "ignores messages it does not handle", %{bypass: bypass} do
      test_pid = self()
      Bypass.stub(bypass, "GET", "/v1/models", &models(&1, test_pid, []))

      pid = start_worker!(enabled: true, interval_ms: 60_000)
      send(pid, {:unexpected, :message})

      assert GenServer.call(pid, :status).check_count == 0
      assert Process.alive?(pid)
      refute_received :http_request
    end
  end

  describe "the worker the application starts" do
    test "status/0 reports it disabled by the test configuration" do
      status = HealthCheckWorker.status()

      assert status.enabled == false
      assert status.interval_ms == 60_000
      assert status.last_check == nil
      assert status.last_results == nil
    end

    test "check_now/0 does not make it check while it is disabled" do
      assert HealthCheckWorker.check_now() == :ok

      # The call is answered after the cast above has been handled.
      assert HealthCheckWorker.status().check_count == 0
    end
  end

  defp start_worker!(opts) do
    pid =
      start_supervised!(
        %{
          id: :health_check_worker,
          start: {GenServer, :start_link, [HealthCheckWorker, opts]}
        },
        restart: :temporary
      )

    # The worker checks the database from its own process.
    Sandbox.allow(Doctrans.Repo, self(), pid)

    pid
  end

  # Every model-list answer also tells the test a request was made, so a test
  # can assert that a disabled worker never asked.
  defp models(conn, test_pid, ids) do
    send(test_pid, :http_request)
    OpenAIBypass.models(conn, ids)
  end

  # The summary is emitted from the worker process, so the handler forwards it
  # to the test instead of being read back out of the worker's state.
  defp attach_summary do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @all_completed,
        fn _event, measurements, _metadata, pid -> send(pid, {:summary, measurements}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
