defmodule Doctrans.Resilience.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Doctrans.Resilience.CircuitBreaker

  setup do
    # Reset fuses before each test
    CircuitBreaker.reset(:openai_api)
    CircuitBreaker.reset(:embedding_api)
    :ok
  end

  describe "install_fuses/0" do
    test "installs fuses without error" do
      assert :ok = CircuitBreaker.install_fuses()
    end
  end

  describe "status/1" do
    test "returns :ok for healthy circuit" do
      assert CircuitBreaker.status(:openai_api) == :ok
    end

    test "returns :blown for open circuit" do
      # Trigger enough failures to blow the fuse
      for _ <- 1..6 do
        CircuitBreaker.melt(:openai_api)
      end

      assert CircuitBreaker.status(:openai_api) == :blown
    end

    test "returns :not_found for unknown fuse" do
      assert CircuitBreaker.status(:unknown_fuse) == :not_found
    end
  end

  describe "status_all/0" do
    test "returns status for all configured fuses" do
      status = CircuitBreaker.status_all()

      assert Map.has_key?(status, :openai_api)
      assert Map.has_key?(status, :embedding_api)
    end
  end

  describe "call/2" do
    test "executes function when circuit is closed" do
      result = CircuitBreaker.call(:openai_api, fn -> {:ok, "success"} end)
      assert result == {:ok, "success"}
    end

    test "returns circuit_open error when circuit is open" do
      # Blow the fuse
      for _ <- 1..6 do
        CircuitBreaker.melt(:openai_api)
      end

      result = CircuitBreaker.call(:openai_api, fn -> {:ok, "should not run"} end)
      assert result == {:error, :circuit_open}
    end

    test "propagates function errors" do
      result = CircuitBreaker.call(:openai_api, fn -> {:error, "something went wrong"} end)
      assert result == {:error, "something went wrong"}
    end

    test "re-raises function exceptions" do
      assert_raise RuntimeError, "boom", fn ->
        CircuitBreaker.call(:openai_api, fn ->
          raise "boom"
        end)
      end
    end
  end

  describe "melt/2" do
    test "reports failure without blowing fuse immediately" do
      CircuitBreaker.melt(:openai_api)
      assert CircuitBreaker.status(:openai_api) == :ok
    end

    test "blows fuse after threshold failures" do
      # Default threshold is 5, need 6 to blow
      for _ <- 1..5 do
        CircuitBreaker.melt(:openai_api)
      end

      assert CircuitBreaker.status(:openai_api) == :ok

      CircuitBreaker.melt(:openai_api)
      assert CircuitBreaker.status(:openai_api) == :blown
    end
  end

  describe "reset/1" do
    test "resets a blown circuit" do
      # Blow the fuse
      for _ <- 1..6 do
        CircuitBreaker.melt(:openai_api)
      end

      assert CircuitBreaker.status(:openai_api) == :blown

      CircuitBreaker.reset(:openai_api)
      assert CircuitBreaker.status(:openai_api) == :ok
    end
  end
end
