defmodule Doctrans.Documents.SweeperWorkerTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.SweeperWorker
  alias Doctrans.TestEnv
  alias Ecto.Adapters.SQL.Sandbox

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  # An hour past the 24 hour grace period the application configures.
  @expired_seconds 25 * 60 * 60

  setup do
    # A sweep deletes every orphaned directory its root holds, so give these
    # cases a root of their own rather than emptying the one the suite shares.
    previous = Application.fetch_env!(:doctrans, :uploads)
    uploads_dir = Path.join(System.tmp_dir!(), "doctrans-sweeper-worker-#{Uniq.UUID.uuid7()}")
    TestEnv.put_env(:uploads, Keyword.put(previous, :upload_dir, uploads_dir))

    documents_dir = Path.join(uploads_dir, "documents")
    File.mkdir_p!(documents_dir)
    on_exit(fn -> File.rm_rf!(uploads_dir) end)

    %{documents_dir: documents_dir}
  end

  describe "init/1" do
    test "an enabled worker reports the schedule it announces" do
      {worker, log} =
        capture_info_log(fn ->
          start_worker(enabled: true, interval_hours: 3, grace_period_hours: 7)
        end)

      assert log =~ "first sweep in 1 minute, then every 3 hours"

      assert GenServer.call(worker, :status) == %{
               enabled: true,
               interval_hours: 3,
               grace_period_hours: 7,
               last_sweep: nil,
               sweep_count: 0,
               last_result: nil
             }
    end

    test "falls back to the documented defaults when nothing is configured" do
      worker = start_worker([])

      assert %{enabled: true, interval_hours: 6, grace_period_hours: 24} =
               GenServer.call(worker, :status)
    end

    test "a disabled worker announces it and sweeps only on demand", %{
      documents_dir: documents_dir
    } do
      orphan = expired_orphan(documents_dir)

      {worker, log} =
        capture_info_log(fn ->
          start_worker(enabled: false, interval_hours: 6, grace_period_hours: 24)
        end)

      assert log =~ "SweeperWorker is disabled"
      assert %{enabled: false, sweep_count: 0, last_sweep: nil} = GenServer.call(worker, :status)
      assert File.exists?(orphan)

      # `enabled: false` only cancels the schedule; an explicit sweep still runs.
      :ok = GenServer.cast(worker, :sweep_now)
      assert %{sweep_count: 1, last_result: {:ok, 1}} = GenServer.call(worker, :status)
      refute File.exists?(orphan)
    end
  end

  describe "handle_info/2" do
    test "a scheduled sweep removes expired orphans and keeps everything else", %{
      documents_dir: documents_dir
    } do
      worker = start_worker(enabled: true, interval_hours: 6, grace_period_hours: 24)
      completed = observe_telemetry([:doctrans, :sweeper, :completed])

      orphan = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(orphan)
      File.write!(Path.join(orphan, "page.png"), "rendered page")
      # Writing into the directory touched it, so age it once its contents are in place.
      expire!(orphan)

      # Old enough to sweep, but the database still knows it.
      document = document_fixture()
      known = expired_orphan(documents_dir, document.id)

      # Unknown to the database, but still inside the grace period.
      recent = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(recent)

      send(worker, :sweep)

      assert %{sweep_count: 1, last_result: {:ok, 1}, last_sweep: %DateTime{}} =
               GenServer.call(worker, :status)

      assert_received {^completed, %{count: 1}, %{}}
      refute File.exists?(orphan)
      assert File.exists?(known)
      assert File.exists?(recent)
    end

    test "an unexpected message leaves the worker untouched" do
      worker = start_worker(enabled: true, interval_hours: 6, grace_period_hours: 24)

      send(worker, {:unexpected, :message})

      assert %{sweep_count: 0, last_sweep: nil, last_result: nil} =
               GenServer.call(worker, :status)
    end

    test "a sweep that cannot read the database records the error and reports it", %{
      documents_dir: documents_dir
    } do
      worker = start_worker(enabled: false, interval_hours: 6, grace_period_hours: 24)
      failed = observe_telemetry([:doctrans, :sweeper, :failed])
      orphan = expired_orphan(documents_dir)

      log =
        capture_log(fn ->
          with_unavailable_documents_table(fn ->
            :ok = GenServer.cast(worker, :sweep_now)

            assert %{sweep_count: 1, last_result: {:error, reason}} =
                     GenServer.call(worker, :status)

            assert reason =~ "documents"
          end)
        end)

      assert log =~ "Sweep failed"
      assert_received {^failed, %{count: 1}, %{error: _reason}}

      # A sweep that could not tell orphans from live documents deleted neither.
      assert File.exists?(orphan)
    end
  end

  describe "the application's worker" do
    test "sweeps on demand through the public API", %{documents_dir: documents_dir} do
      orphan = expired_orphan(documents_dir)
      before = SweeperWorker.status()

      assert :ok = SweeperWorker.sweep_now()

      # A call is answered after the cast queued ahead of it, so the sweep has
      # already run by the time the status below is built.
      status = SweeperWorker.status()
      assert status.sweep_count > before.sweep_count
      assert %DateTime{} = status.last_sweep
      assert {:ok, _count} = status.last_result
      refute File.exists?(orphan)
    end
  end

  # The application owns the registered name, so the instance under test runs
  # unnamed and is stopped with the case — nothing it schedules outlives it.
  defp start_worker(config) do
    TestEnv.put_env(SweeperWorker, config)

    worker =
      start_supervised!(
        %{
          id: :sweeper_worker_under_test,
          start: {GenServer, :start_link, [SweeperWorker, []]}
        },
        restart: :temporary
      )

    Sandbox.allow(Repo, self(), worker)
    worker
  end

  defp expired_orphan(documents_dir, name \\ Ecto.UUID.generate()) do
    path = Path.join(documents_dir, name)
    File.mkdir_p!(path)
    expire!(path)
  end

  # The sweeper ages a directory by its own mtime, not by what it contains.
  defp expire!(path) do
    File.touch!(path, System.os_time(:second) - @expired_seconds)
    path
  end

  # The suite runs Logger at :warning, where an :info message is never built,
  # let alone emitted — and both startup announcements are :info.
  defp capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    try do
      with_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp observe_telemetry(event) do
    owner = self()
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          send(owner, {handler_id, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp with_unavailable_documents_table(fun) do
    Repo.query!("ALTER TABLE documents RENAME TO unavailable_documents")

    try do
      fun.()
    after
      # The SQL sandbox isolates the query failure with its own savepoint.
      Repo.query!("ALTER TABLE unavailable_documents RENAME TO documents")
    end
  end
end
