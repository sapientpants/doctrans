defmodule Doctrans.Resilience.HealthCheckWorkerTest do
  use ExUnit.Case, async: false

  alias Doctrans.Resilience.{CircuitBreaker, HealthCheckWorker}

  # These tests verify the GenServer behavior without making real external calls.
  # The worker is disabled in test config, so we test static status responses.

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

    test "returns disabled when configured as such" do
      status = HealthCheckWorker.status()
      # Worker is disabled in test config
      assert status.enabled == false
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

  describe "check_now/0" do
    test "returns :ok without blocking" do
      # When disabled, check_now should return immediately
      assert :ok == HealthCheckWorker.check_now()
    end
  end
end
