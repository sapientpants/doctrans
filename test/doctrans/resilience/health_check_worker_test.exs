defmodule Doctrans.Resilience.HealthCheckWorkerTest do
  @moduledoc """
  Drives the worker's own check cycle.

  `config/test.exs` disables the worker the application starts, because a
  worker left enabled would run real checks on its interval for the whole
  suite. These tests therefore start their own instance instead: the module
  reads its settings from the application environment at `init/1`, so
  `Doctrans.TestEnv` sets them for the test and the instance is started
  unnamed, next to the disabled one. The OpenAI probe reaches a local Bypass
  server and the database probe runs on the shared sandbox connection, so a
  cycle is driven end to end without touching the network.
  """

  use Doctrans.DataCase, async: false

  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.HealthCheckWorker
  alias Doctrans.TestEnv
  alias Ecto.Adapters.SQL.Sandbox

  @all_completed [:doctrans, :health_check, :all_completed]

  setup do
    CircuitBreaker.reset(:openai_api)
    CircuitBreaker.reset(:embedding_api)

    bypass = Bypass.open()
    TestEnv.put_env(:openai, base_url: "http://localhost:#{bypass.port}", api_key: "sk-test-123")

    on_exit(fn ->
      CircuitBreaker.reset(:openai_api)
      CircuitBreaker.reset(:embedding_api)
    end)

    %{bypass: bypass}
  end

  describe "init/1" do
    test "reports its configuration before the first check has run" do
      pid = start_worker!(enabled: true, interval_ms: 30_000, auto_reset_circuits: false)

      assert GenServer.call(pid, :status) == %{
               enabled: true,
               interval_ms: 30_000,
               auto_reset_circuits: false,
               last_check: nil,
               last_results: nil,
               check_count: 0,
               circuit_breakers: %{openai_api: :ok, embedding_api: :ok}
             }
    end

    test "falls back to the module defaults when nothing is configured" do
      pid = start_worker!([])

      status = GenServer.call(pid, :status)

      assert status.enabled
      assert status.interval_ms == 60_000
      assert status.auto_reset_circuits
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

  describe "circuit breaker auto-reset" do
    test "resets the API circuits once OpenAI answers again", %{bypass: bypass} do
      pid = start_worker!(enabled: true, interval_ms: 60_000, auto_reset_circuits: true)

      Bypass.expect(bypass, "GET", "/v1/models", &Plug.Conn.resp(&1, 401, "unauthorized"))
      GenServer.cast(pid, :check_now)
      assert {:error, _} = GenServer.call(pid, :status).last_results.openai

      # The embedding fuse is the observable one: a blown `:openai_api` fuse
      # would short-circuit the probe, so the check could never see a recovery.
      blow(:embedding_api)

      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, ["gpt-4o-mini"]))
      GenServer.cast(pid, :check_now)

      assert GenServer.call(pid, :status).circuit_breakers == %{
               openai_api: :ok,
               embedding_api: :ok
             }
    end

    test "leaves the circuits alone while OpenAI is still failing", %{bypass: bypass} do
      pid = start_worker!(enabled: true, interval_ms: 60_000, auto_reset_circuits: true)

      Bypass.expect(bypass, "GET", "/v1/models", &Plug.Conn.resp(&1, 401, "unauthorized"))
      GenServer.cast(pid, :check_now)

      blow(:embedding_api)

      # A second failing check: the previous verdict was a failure too, so
      # there is no recovery to act on.
      GenServer.cast(pid, :check_now)
      status = GenServer.call(pid, :status)

      assert status.last_results.openai == {:error, {:http_error, [status: 401]}}
      assert status.circuit_breakers.embedding_api == :blown
    end

    test "leaves the circuits alone when the reset is switched off", %{bypass: bypass} do
      pid = start_worker!(enabled: true, interval_ms: 60_000, auto_reset_circuits: false)

      Bypass.expect(bypass, "GET", "/v1/models", &Plug.Conn.resp(&1, 401, "unauthorized"))
      GenServer.cast(pid, :check_now)

      blow(:embedding_api)

      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, ["gpt-4o-mini"]))
      GenServer.cast(pid, :check_now)

      assert GenServer.call(pid, :status).circuit_breakers.embedding_api == :blown
    end

    test "leaves the circuits alone when OpenAI was healthy all along", %{bypass: bypass} do
      test_pid = self()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, test_pid, ["gpt-4o-mini"]))

      pid = start_worker!(enabled: true, interval_ms: 60_000, auto_reset_circuits: true)
      GenServer.cast(pid, :check_now)
      assert {:ok, _} = GenServer.call(pid, :status).last_results.openai

      blow(:embedding_api)
      GenServer.cast(pid, :check_now)

      assert GenServer.call(pid, :status).circuit_breakers.embedding_api == :blown
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
    TestEnv.put_env(HealthCheckWorker, opts)

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

  defp models(conn, test_pid, ids) do
    send(test_pid, :http_request)
    body = %{"object" => "list", "data" => Enum.map(ids, &%{"id" => &1})}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp blow(fuse_name) do
    for _ <- 1..6, do: CircuitBreaker.melt(fuse_name)
    :blown = CircuitBreaker.status(fuse_name)
    :ok
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
