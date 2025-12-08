defmodule Doctrans.Resilience.Backoff do
  @moduledoc """
  Exponential backoff with jitter for retry logic.

  Calculates delay times that grow exponentially with each attempt,
  adding random jitter to prevent thundering herd problems.

  ## Configuration

  - `:base` - Base delay in milliseconds (default: 2000)
  - `:max` - Maximum delay in milliseconds (default: 30000)
  - `:multiplier` - Multiplier for each attempt (default: 2)
  - `:jitter` - Jitter percentage as decimal 0.0-1.0 (default: 0.25)

  ## Example

      iex> Backoff.calculate(0, base: 1000, jitter: 0)
      1000
      iex> Backoff.calculate(1, base: 1000, jitter: 0)
      2000
      iex> Backoff.calculate(2, base: 1000, jitter: 0)
      4000
  """

  @default_base 2_000
  @default_max 30_000
  @default_multiplier 2
  @default_jitter 0.25

  @doc """
  Calculates the delay for a given attempt number.

  ## Options

  - `:base` - Base delay in milliseconds (default: #{@default_base})
  - `:max` - Maximum delay in milliseconds (default: #{@default_max})
  - `:multiplier` - Multiplier for each attempt (default: #{@default_multiplier})
  - `:jitter` - Jitter percentage as decimal 0.0-1.0 (default: #{@default_jitter})

  ## Examples

      iex> delay = Backoff.calculate(0)
      iex> delay >= 1500 and delay <= 2500
      true

      iex> Backoff.calculate(3, base: 1000, max: 5000, jitter: 0)
      5000
  """
  @spec calculate(non_neg_integer(), keyword()) :: non_neg_integer()
  def calculate(attempt, opts \\ []) when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :base, @default_base)
    max = Keyword.get(opts, :max, @default_max)
    multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
    jitter = Keyword.get(opts, :jitter, @default_jitter)

    # Calculate exponential delay
    delay = base * Integer.pow(multiplier, attempt)

    # Cap at maximum
    delay = min(delay, max)

    # Add jitter
    add_jitter(delay, jitter)
  end

  @doc """
  Sleeps for the calculated backoff duration.

  Returns the actual sleep duration in milliseconds.
  """
  @spec sleep(non_neg_integer(), keyword()) :: non_neg_integer()
  def sleep(attempt, opts \\ []) do
    delay = calculate(attempt, opts)
    Process.sleep(delay)
    delay
  end

  defp add_jitter(delay, 0), do: delay
  defp add_jitter(delay, +0.0), do: delay

  defp add_jitter(delay, jitter) when jitter > 0 do
    # Calculate jitter range
    jitter_amount = round(delay * jitter)

    # Generate random offset between -jitter_amount and +jitter_amount
    offset = :rand.uniform(jitter_amount * 2 + 1) - jitter_amount - 1

    # Ensure we don't go below 0
    max(0, delay + offset)
  end
end
