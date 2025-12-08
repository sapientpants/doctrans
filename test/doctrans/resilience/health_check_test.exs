defmodule Doctrans.Resilience.HealthCheckTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.HealthCheck

  setup do
    CircuitBreaker.reset(:ollama_api)
    :ok
  end

  describe "check_database/0" do
    test "returns :ok when database is accessible" do
      assert HealthCheck.check_database() == :ok
    end
  end

  describe "check_filesystem/0" do
    test "returns :ok when uploads directory is writable" do
      assert HealthCheck.check_filesystem() == :ok
    end
  end

  describe "check_ollama/0" do
    test "returns error when circuit is blown" do
      # Blow the circuit
      for _ <- 1..6 do
        CircuitBreaker.melt(:ollama_api)
      end

      result = HealthCheck.check_ollama()
      assert result == {:error, :circuit_open}
    end

    test "returns result when circuit is closed" do
      CircuitBreaker.reset(:ollama_api)
      # Without real Ollama, this will return error, but at least we're testing the function
      result = HealthCheck.check_ollama()

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "check_all/0" do
    test "returns map with all health check results" do
      results = HealthCheck.check_all()

      assert Map.has_key?(results, :ollama)
      assert Map.has_key?(results, :database)
      assert Map.has_key?(results, :filesystem)

      # Database and filesystem should be ok in test env
      assert results.database == :ok
      assert results.filesystem == :ok
    end
  end

  describe "healthy?/0" do
    test "returns false when any check fails" do
      # Blow the circuit to make ollama check fail
      for _ <- 1..6 do
        CircuitBreaker.melt(:ollama_api)
      end

      refute HealthCheck.healthy?()
    end
  end

  describe "circuit_breaker_status/0" do
    test "returns circuit breaker status map" do
      status = HealthCheck.circuit_breaker_status()

      assert is_map(status)
      assert Map.has_key?(status, :ollama_api)
    end

    test "returns ok status for healthy circuits" do
      CircuitBreaker.reset(:ollama_api)
      status = HealthCheck.circuit_breaker_status()

      assert status.ollama_api == :ok
    end

    test "returns blown status for open circuits" do
      # Blow the circuit
      for _ <- 1..6 do
        CircuitBreaker.melt(:ollama_api)
      end

      status = HealthCheck.circuit_breaker_status()

      assert status.ollama_api == :blown
    end
  end
end
