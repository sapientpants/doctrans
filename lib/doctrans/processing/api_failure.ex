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
  Turns a `Req` result into the caller's `{:ok, value}` or a reported failure.

  Every way a call can fail -- a non-2xx, a transport error, or a 200 whose body
  `parser` rejects -- goes through `handle/3`, so each failure is logged once at
  the source, classified once, and leaves in the normalized shape. A malformed
  body never melts the fuse: the classifier calls it permanent or unknown, not
  transient. `opts` are `handle/3`'s.
  """
  @spec resolve(
          {:ok, Req.Response.t()} | {:error, reason()},
          atom(),
          (term() -> {:ok, value} | {:error, reason()}),
          keyword()
        ) :: {:ok, value} | {:error, Doctrans.Errors.reason()}
        when value: var
  def resolve(result, fuse, parser, opts \\ [])

  def resolve({:ok, %Req.Response{status: 200, body: body}}, fuse, parser, opts) do
    case parser.(body) do
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> handle(fuse, error, opts)
    end
  end

  def resolve({:ok, %Req.Response{status: status} = resp}, fuse, _parser, opts) do
    handle(fuse, {:http_status, status, resp}, opts)
  end

  def resolve({:error, reason}, fuse, _parser, opts) do
    handle(fuse, reason, opts)
  end

  @doc """
  Reports `reason` against `fuse` and returns the normalized `{:error, _}`.

  `melt: false` reports the failure without counting it against the fuse. It is
  for calls a user can re-trigger at will from the UI: `:openai_api` is shared
  with extraction, translation, chat and background jobs, so a button that melts
  it lets one impatient reader disable processing for everyone else.
  """
  @spec handle(atom(), reason(), keyword()) :: {:error, Doctrans.Errors.reason()}
  def handle(fuse, reason, opts \\ []) do
    normalized = reason |> source_reason() |> Doctrans.Errors.normalize()
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
    {:error, normalized}
  end

  # The client's `{:http_status, status, resp}` tuple becomes the source shape
  # `{:http_error, status}`, which `Doctrans.Errors.normalize/1` then turns into
  # the `{:http_error, [status: status]}` every consumer -- classifier, job,
  # message catalog -- is written against.
  defp source_reason({:http_status, status, _resp}), do: {:http_error, status}

  defp source_reason({:error, reason}), do: source_reason(reason)

  defp source_reason(reason), do: reason
end
