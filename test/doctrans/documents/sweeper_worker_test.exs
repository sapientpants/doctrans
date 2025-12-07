defmodule Doctrans.Documents.SweeperWorkerTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.SweeperWorker

  describe "status/0" do
    test "returns current worker status" do
      status = SweeperWorker.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :interval_hours)
      assert Map.has_key?(status, :grace_period_hours)
      assert Map.has_key?(status, :last_sweep)
      assert Map.has_key?(status, :sweep_count)
    end

    test "returns configured values" do
      status = SweeperWorker.status()

      # Check that defaults or configured values are present
      assert is_boolean(status.enabled)
      assert is_integer(status.interval_hours)
      assert is_integer(status.grace_period_hours)
    end
  end

  describe "sweep_now/0" do
    test "triggers an immediate sweep" do
      initial_status = SweeperWorker.status()
      initial_count = initial_status.sweep_count

      :ok = SweeperWorker.sweep_now()

      # Give the async cast time to process (increased for reliability)
      Process.sleep(500)

      new_status = SweeperWorker.status()
      assert new_status.sweep_count == initial_count + 1
      assert new_status.last_sweep != nil
    end

    test "updates last_sweep timestamp" do
      :ok = SweeperWorker.sweep_now()
      Process.sleep(500)

      status = SweeperWorker.status()
      assert %DateTime{} = status.last_sweep
    end
  end
end
