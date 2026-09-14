defmodule Doctrans.Processing.ApiFailure do
  @moduledoc """
  Turns a failed OpenAI-compatible API call into a normalized error, deciding
  along the way whether it counts against a circuit breaker.

  Extracted from `Doctrans.Processing.OpenAI`, which reaches this path from
  every call it makes -- completions, streaming, model listing and embedding --
  against two different fuses.
  """

  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.ErrorClassifier

  require Logger

  @type reason :: term()

  @doc """
  Reports `reason` against `fuse` and returns the normalized `{:error, _}`.

  `melt: false` reports the failure without counting it against the fuse. It is
  for calls a user can re-trigger at will from the UI: `:openai_api` is shared
  with extraction, translation, chat and background jobs, so a button that melts
  it lets one impatient reader disable processing for everyone else.
  """
  @spec handle(atom(), reason(), keyword()) :: {:error, Doctrans.Errors.reason()}
  def handle(fuse, reason, opts \\ []) do
    normalized = normalize_reason(reason)
    classification = ErrorClassifier.classify(normalized)

    cond do
      classification != :retryable ->
        Logger.debug(
          "Not melting fuse #{to_string(fuse)} for #{classification} error: #{inspect(reason)}"
        )

      Keyword.get(opts, :melt, true) ->
        # Only transient/5xx/transport failures count against the circuit
        # breaker; a single 401 or bad request must not push it toward blown.
        CircuitBreaker.melt(fuse, reason)

      true ->
        Logger.debug("Not melting fuse #{to_string(fuse)} for user-triggered retryable error")
    end

    # `reason` can be `{:http_status, status, %Req.Response{}}`, and an
    # OpenAI-compatible server commonly echoes the offending request in a 4xx
    # body -- which for an embedding call is the user's search text. The
    # normalized shape carries the status without the payload, so only that goes
    # out at the production log level; the raw reason stays behind :debug.
    Logger.error("API call failed (#{classification}): #{inspect(normalized)}")
    Logger.debug("API call failure detail: #{inspect(reason)}")
    {:error, Doctrans.Errors.normalize(normalized)}
  end

  # ErrorClassifier keys HTTP failures as {:http_error, status}, so map our
  # internal {:http_status, status, resp} tuple onto that shape.
  defp normalize_reason({:http_status, status, _resp}), do: {:http_error, status}

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)

  defp normalize_reason(reason), do: reason
end
