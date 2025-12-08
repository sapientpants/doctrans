defmodule Doctrans.Resilience.ErrorClassifier do
  @moduledoc """
  Classifies errors as retryable or permanent.

  Used to determine whether an operation should be retried or
  immediately marked as failed.

  ## Classifications

  - `:retryable` - Transient errors that may succeed on retry:
    - Timeouts
    - Connection errors
    - 5xx server errors
    - 429 rate limiting

  - `:permanent` - Errors that won't be fixed by retrying:
    - 4xx client errors (except 429)
    - Validation errors
    - File not found
    - Model not found

  - `:unknown` - Unrecognized errors (treated as retryable by default)
  """

  @type classification :: :retryable | :permanent | :unknown

  @doc """
  Classifies an error as retryable, permanent, or unknown.

  ## Examples

      iex> ErrorClassifier.classify(:timeout)
      :retryable

      iex> ErrorClassifier.classify({:error, %Req.TransportError{reason: :timeout}})
      :retryable

      iex> ErrorClassifier.classify({:http_error, 404})
      :permanent

      iex> ErrorClassifier.classify({:http_error, 500})
      :retryable
  """
  @spec classify(term()) :: classification()
  def classify(error)

  # Explicit timeout atoms
  def classify(:timeout), do: :retryable
  def classify({:error, :timeout}), do: :retryable

  # Req transport errors
  def classify({:error, %Req.TransportError{reason: :timeout}}), do: :retryable
  def classify({:error, %Req.TransportError{reason: :econnrefused}}), do: :retryable
  def classify({:error, %Req.TransportError{reason: :econnreset}}), do: :retryable
  def classify({:error, %Req.TransportError{reason: :closed}}), do: :retryable
  def classify({:error, %Req.TransportError{reason: :nxdomain}}), do: :retryable
  def classify({:error, %Req.TransportError{}}), do: :retryable

  # Raw transport error patterns
  def classify(%Req.TransportError{}), do: :retryable

  # HTTP status codes
  def classify({:http_error, status}) when status == 429, do: :retryable
  def classify({:http_error, status}) when status >= 500 and status < 600, do: :retryable
  def classify({:http_error, status}) when status >= 400 and status < 500, do: :permanent

  # File errors
  def classify({:error, :enoent}), do: :permanent
  def classify({:error, :eacces}), do: :permanent
  def classify({:error, :enotdir}), do: :permanent

  # Generic error tuples
  def classify({:error, reason}) when is_atom(reason) do
    case reason do
      :timeout -> :retryable
      :econnrefused -> :retryable
      :econnreset -> :retryable
      :closed -> :retryable
      :nxdomain -> :retryable
      :enoent -> :permanent
      :eacces -> :permanent
      _ -> :unknown
    end
  end

  def classify({:error, reason}) when is_binary(reason), do: classify(reason)

  # String error messages (common patterns)
  def classify(error) when is_binary(error) do
    cond do
      retryable_string?(error) -> :retryable
      permanent_string?(error) -> :permanent
      true -> :unknown
    end
  end

  # Catch-all
  def classify(_), do: :unknown

  defp retryable_string?(error) do
    retryable_patterns = [
      "timeout",
      "timed out",
      "connection refused",
      "connection reset",
      "503",
      "502",
      "500",
      "429",
      "rate limit"
    ]

    Enum.any?(retryable_patterns, &String.contains?(error, &1))
  end

  defp permanent_string?(error) do
    permanent_patterns = ["not found", "404", "400", "invalid"]
    model_not_found = String.contains?(error, "model") and String.contains?(error, "not")

    Enum.any?(permanent_patterns, &String.contains?(error, &1)) or model_not_found
  end

  @doc """
  Returns true if the error is classified as retryable.

  Unknown errors are treated as retryable by default.

  ## Examples

      iex> ErrorClassifier.retryable?(:timeout)
      true

      iex> ErrorClassifier.retryable?({:http_error, 404})
      false
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(error) do
    case classify(error) do
      :retryable -> true
      :unknown -> true
      :permanent -> false
    end
  end

  @doc """
  Returns true if the error is classified as permanent.

  ## Examples

      iex> ErrorClassifier.permanent?({:http_error, 404})
      true

      iex> ErrorClassifier.permanent?(:timeout)
      false
  """
  @spec permanent?(term()) :: boolean()
  def permanent?(error) do
    classify(error) == :permanent
  end
end
