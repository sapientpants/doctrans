defmodule Doctrans.Resilience.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Doctrans.Resilience.ErrorClassifier

  describe "classify/1" do
    test "classifies timeout atom as retryable" do
      assert ErrorClassifier.classify(:timeout) == :retryable
    end

    test "classifies {:error, :timeout} as retryable" do
      assert ErrorClassifier.classify({:error, :timeout}) == :retryable
    end

    test "classifies transport errors as retryable" do
      assert ErrorClassifier.classify({:error, %Req.TransportError{reason: :timeout}}) ==
               :retryable

      assert ErrorClassifier.classify({:error, %Req.TransportError{reason: :econnrefused}}) ==
               :retryable

      assert ErrorClassifier.classify({:error, %Req.TransportError{reason: :econnreset}}) ==
               :retryable

      assert ErrorClassifier.classify({:error, %Req.TransportError{reason: :closed}}) ==
               :retryable

      assert ErrorClassifier.classify({:error, %Req.TransportError{reason: :nxdomain}}) ==
               :retryable

      assert ErrorClassifier.classify(%Req.TransportError{reason: :other}) == :retryable
    end

    test "classifies HTTP 5xx errors as retryable" do
      assert ErrorClassifier.classify({:http_error, 500}) == :retryable
      assert ErrorClassifier.classify({:http_error, 502}) == :retryable
      assert ErrorClassifier.classify({:http_error, 503}) == :retryable
      assert ErrorClassifier.classify({:http_error, 599}) == :retryable
    end

    test "classifies HTTP 429 as retryable" do
      assert ErrorClassifier.classify({:http_error, 429}) == :retryable
    end

    test "classifies HTTP 4xx errors as permanent" do
      assert ErrorClassifier.classify({:http_error, 400}) == :permanent
      assert ErrorClassifier.classify({:http_error, 404}) == :permanent
      assert ErrorClassifier.classify({:http_error, 422}) == :permanent
    end

    test "classifies file errors as permanent" do
      assert ErrorClassifier.classify({:error, :enoent}) == :permanent
      assert ErrorClassifier.classify({:error, :eacces}) == :permanent
      assert ErrorClassifier.classify({:error, :enotdir}) == :permanent
    end

    test "classifies string errors with timeout keywords as retryable" do
      assert ErrorClassifier.classify("connection timeout") == :retryable
      assert ErrorClassifier.classify("request timed out") == :retryable
      assert ErrorClassifier.classify("connection refused") == :retryable
      assert ErrorClassifier.classify("connection reset by peer") == :retryable
      assert ErrorClassifier.classify("HTTP 500 error") == :retryable
      assert ErrorClassifier.classify("rate limit exceeded") == :retryable
    end

    test "classifies string errors with permanent keywords" do
      assert ErrorClassifier.classify("resource not found") == :permanent
      assert ErrorClassifier.classify("HTTP 404") == :permanent
      assert ErrorClassifier.classify("invalid request") == :permanent
      assert ErrorClassifier.classify("model xyz not available") == :permanent
    end

    test "classifies generic atom errors" do
      assert ErrorClassifier.classify({:error, :econnrefused}) == :retryable
      assert ErrorClassifier.classify({:error, :unknown_error}) == :unknown
    end

    test "classifies binary error reasons" do
      assert ErrorClassifier.classify({:error, "timeout occurred"}) == :retryable
      assert ErrorClassifier.classify({:error, "not found"}) == :permanent
    end

    test "returns unknown for unrecognized errors" do
      assert ErrorClassifier.classify(:some_random_error) == :unknown
      assert ErrorClassifier.classify({:error, {:complex, :error}}) == :unknown
      assert ErrorClassifier.classify("some random message") == :unknown
    end
  end

  describe "retryable?/1" do
    test "returns true for retryable errors" do
      assert ErrorClassifier.retryable?(:timeout) == true
      assert ErrorClassifier.retryable?({:http_error, 500}) == true
    end

    test "returns true for unknown errors (default to retry)" do
      assert ErrorClassifier.retryable?(:some_unknown) == true
    end

    test "returns false for permanent errors" do
      assert ErrorClassifier.retryable?({:http_error, 404}) == false
      assert ErrorClassifier.retryable?({:error, :enoent}) == false
    end
  end

  describe "permanent?/1" do
    test "returns true for permanent errors" do
      assert ErrorClassifier.permanent?({:http_error, 404}) == true
      assert ErrorClassifier.permanent?({:error, :enoent}) == true
    end

    test "returns false for retryable errors" do
      assert ErrorClassifier.permanent?(:timeout) == false
      assert ErrorClassifier.permanent?({:http_error, 500}) == false
    end

    test "returns false for unknown errors" do
      assert ErrorClassifier.permanent?(:some_unknown) == false
    end
  end
end
