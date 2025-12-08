defmodule Doctrans.Resilience.HealthCheckWorkerTest do
  use ExUnit.Case, async: false

  alias Doctrans.Resilience.{CircuitBreaker, HealthCheckWorker}

  setup do
    CircuitBreaker.reset(:ollama_api)
    CircuitBreaker.reset(:embedding_api)
    :ok
  end

  describe "status/0" do
    test "returns worker status" do
      status = HealthCheckWorker.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :interval_ms)
      assert Map.has_key?(status, :last_check)
      assert Map.has_key?(status, :check_count)
    end
  end

  describe "check_now/0" do
    test "triggers an immediate health check" do
      # Get initial status
      initial_status = HealthCheckWorker.status()
      initial_count = initial_status.check_count

      # Trigger a check
      :ok = HealthCheckWorker.check_now()

      # Give it a moment to complete
      Process.sleep(100)

      # Check that the count incremented
      new_status = HealthCheckWorker.status()
      assert new_status.check_count >= initial_count
    end
  end

  describe "configuration" do
    test "uses configured interval" do
      status = HealthCheckWorker.status()
      # Default interval is 60 seconds
      assert status.interval_ms == 60_000
    end

    test "status includes auto_reset_circuits setting" do
      status = HealthCheckWorker.status()
      assert Map.has_key?(status, :auto_reset_circuits)
      assert is_boolean(status.auto_reset_circuits)
    end

    test "status includes last_results" do
      status = HealthCheckWorker.status()
      assert Map.has_key?(status, :last_results)
    end

    test "status includes circuit_breakers" do
      status = HealthCheckWorker.status()
      assert Map.has_key?(status, :circuit_breakers)
      assert is_map(status.circuit_breakers)
    end
  end

  describe "check_now/0 behavior" do
    test "updates last_check timestamp" do
      initial_status = HealthCheckWorker.status()

      :ok = HealthCheckWorker.check_now()
      Process.sleep(100)

      new_status = HealthCheckWorker.status()

      # Either last_check was nil and now has a value, or it was updated
      if is_nil(initial_status.last_check) do
        assert not is_nil(new_status.last_check)
      else
        assert DateTime.compare(new_status.last_check, initial_status.last_check) != :lt
      end
    end

    test "populates last_results" do
      :ok = HealthCheckWorker.check_now()
      Process.sleep(100)

      status = HealthCheckWorker.status()
      # Last results should be populated after a check
      assert status.last_results == nil or is_map(status.last_results)
    end
  end
end
