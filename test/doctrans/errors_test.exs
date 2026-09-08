defmodule Doctrans.ErrorsTest do
  use ExUnit.Case, async: true

  alias Doctrans.Errors
  alias Doctrans.Resilience.ErrorClassifier

  test "normalized HTTP and transport errors preserve retry decisions" do
    for {status, classification} <- [
          {400, :permanent},
          {401, :permanent},
          {404, :permanent},
          {429, :retryable},
          {500, :retryable},
          {503, :retryable}
        ] do
      reason = Errors.normalize({:http_error, status})
      assert reason == {:http_error, [status: status]}
      assert ErrorClassifier.classify(reason) == classification
    end

    reason = Errors.normalize(%Req.TransportError{reason: :econnrefused})
    assert reason == {:transport_error, [reason: :econnrefused]}
    assert ErrorClassifier.classify(reason) == :retryable
    assert ErrorClassifier.classify({:image_unreadable, [reason: :enoent]}) == :permanent
  end
end
