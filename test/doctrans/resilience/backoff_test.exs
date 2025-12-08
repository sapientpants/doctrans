defmodule Doctrans.Resilience.BackoffTest do
  use ExUnit.Case, async: true

  alias Doctrans.Resilience.Backoff

  describe "calculate/2" do
    test "returns base delay for attempt 0" do
      # With 0 jitter for predictable testing
      assert Backoff.calculate(0, base: 1000, jitter: 0) == 1000
    end

    test "doubles delay for each attempt" do
      assert Backoff.calculate(1, base: 1000, jitter: 0) == 2000
      assert Backoff.calculate(2, base: 1000, jitter: 0) == 4000
      assert Backoff.calculate(3, base: 1000, jitter: 0) == 8000
    end

    test "caps delay at max value" do
      assert Backoff.calculate(10, base: 1000, max: 5000, jitter: 0) == 5000
    end

    test "applies jitter within expected range" do
      base = 1000
      jitter = 0.25

      # Run multiple times to verify jitter is applied
      delays = for _ <- 1..100, do: Backoff.calculate(0, base: base, jitter: jitter)

      # With 25% jitter, values should be between 750 and 1250
      assert Enum.all?(delays, fn d -> d >= 750 and d <= 1250 end)

      # Should have some variation (not all the same value)
      assert length(Enum.uniq(delays)) > 1
    end

    test "uses default values" do
      delay = Backoff.calculate(0)
      # Default base is 2000, jitter is 0.25, so range is 1500-2500
      assert delay >= 1500 and delay <= 2500
    end

    test "handles zero jitter float" do
      assert Backoff.calculate(0, base: 1000, jitter: 0.0) == 1000
    end

    test "handles custom multiplier" do
      assert Backoff.calculate(1, base: 1000, multiplier: 3, jitter: 0) == 3000
      assert Backoff.calculate(2, base: 1000, multiplier: 3, jitter: 0) == 9000
    end
  end

  describe "sleep/2" do
    test "sleeps and returns the delay" do
      start = System.monotonic_time(:millisecond)
      delay = Backoff.sleep(0, base: 50, jitter: 0)
      elapsed = System.monotonic_time(:millisecond) - start

      assert delay == 50
      assert elapsed >= 45
    end
  end
end
