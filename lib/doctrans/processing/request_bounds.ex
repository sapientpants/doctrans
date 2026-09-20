defmodule Doctrans.Processing.RequestBounds do
  @moduledoc """
  Wall-clock and size bounds for one OpenAI-compatible API call.

  Req's `:receive_timeout` bounds a single receive, not a request: an endpoint
  that drips one byte a minute resets it forever, and with `retry: :transient`
  the same stall is paid again on every attempt -- three 300 s attempts plus
  backoff is the twenty minutes a page could be held for. Req also puts no bound
  on how much body it will buffer, so a broken or hostile endpoint can answer a
  page request with an unbounded stream.

  `new/1` fixes one monotonic deadline for the whole call. Requests made through
  `post/3` and `get/3` stream their body through `into:`, so every chunk is
  checked against that deadline and against the byte budget *before* it is
  appended, and a retry only starts while a full attempt still fits inside the
  deadline. A bounded call therefore returns inside its deadline whether the
  endpoint hangs silently, drips forever, or floods.

  Under the cap the accumulated body is an ordinary binary, so Req's own
  response steps still decode it; over the cap the accumulator is replaced by a
  marker, which both halts the stream and keeps the decoders off a payload that
  was cut in half.

  Tripped bounds surface as `:inference_deadline_exceeded` and
  `{:inference_response_too_large, limit: bytes}`, which
  `Doctrans.Processing.ApiFailure` normalizes like any other client failure.
  """

  alias Doctrans.Config.OpenAI

  @typedoc "One call's remaining budget: a monotonic deadline and a byte cap."
  @type t :: %__MODULE__{
          deadline: integer(),
          attempt_timeout: pos_integer(),
          max_bytes: pos_integer()
        }

  @enforce_keys [:deadline, :attempt_timeout, :max_bytes]
  defstruct [:deadline, :attempt_timeout, :max_bytes]

  # Body marker for a call whose bound tripped mid-stream. A tuple rather than a
  # binary so Req's `decode_body` step skips it instead of failing on a partial
  # JSON payload.
  @exceeded :doctrans_bounds_exceeded
  @bytes_key :doctrans_response_bytes

  @doc """
  Fixes the budget for one call, starting now.

  ## Options

  - `:timeout` - milliseconds one receive may take (default:
    `Doctrans.Config.OpenAI.timeout/0`). Clamped to the total budget, since an
    attempt cannot usefully outlive the deadline it runs under.
  - `:deadline` - milliseconds the whole call may take, retries included
    (default: `Doctrans.Config.OpenAI.deadline/0`)
  - `:max_response_bytes` - how much response body may be accepted (default:
    `Doctrans.Config.OpenAI.max_response_bytes/0`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    total = Keyword.get(opts, :deadline) || OpenAI.deadline()
    timeout = Keyword.get(opts, :timeout) || OpenAI.timeout()

    %__MODULE__{
      deadline: System.monotonic_time(:millisecond) + total,
      attempt_timeout: min(timeout, total),
      max_bytes: Keyword.get(opts, :max_response_bytes) || OpenAI.max_response_bytes()
    }
  end

  @doc "Milliseconds left before the deadline; negative once it has passed."
  @spec remaining(t()) :: integer()
  def remaining(%__MODULE__{deadline: deadline}),
    do: deadline - System.monotonic_time(:millisecond)

  @doc """
  Runs a bounded POST.

  Takes the usual Req options, plus `:collect` -- a `(binary(), term() -> term())`
  reducer folding each chunk into the response body, for a caller that parses as
  it streams. It defaults to plain accumulation, which is what a non-streaming
  call wants.
  """
  @spec post(Req.Request.t(), t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post(req, bounds, options), do: request(req, bounds, [{:method, :post} | options])

  @doc "Runs a bounded GET. See `post/3` for the options."
  @spec get(Req.Request.t(), t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def get(req, bounds, options), do: request(req, bounds, [{:method, :get} | options])

  defp request(req, bounds, options) do
    {collect, options} = Keyword.pop(options, :collect, &append/2)
    {mode, options} = Keyword.pop(options, :retry, :transient)

    req
    |> Req.request(
      Keyword.merge(options,
        receive_timeout: bounds.attempt_timeout,
        retry: retry_fun(bounds, mode),
        into: into(bounds, collect)
      )
    )
    |> unwrap(bounds)
  end

  defp append(data, body), do: body <> data

  # The size check runs before the chunk is folded in, so an oversized body is
  # refused rather than buffered and then measured.
  defp into(bounds, collect) do
    fn {:data, data}, {req, resp} ->
      bytes = Map.get(resp.private, @bytes_key, 0) + byte_size(data)

      cond do
        bytes > bounds.max_bytes ->
          halt(req, resp, {:inference_response_too_large, limit: bounds.max_bytes})

        remaining(bounds) <= 0 ->
          halt(req, resp, :inference_deadline_exceeded)

        true ->
          resp = %{resp | body: collect.(data, resp.body)}
          {:cont, {req, Req.Response.put_private(resp, @bytes_key, bytes)}}
      end
    end
  end

  defp halt(req, resp, reason), do: {:halt, {req, %{resp | body: {@exceeded, reason}}}}

  # A bound tripped on an error response is reported as the status it
  # interrupted: which status the server sent is the more actionable fact, and
  # nothing downstream reads the body of a failed response.
  defp unwrap({:ok, %Req.Response{status: 200, body: {@exceeded, reason}}}, _bounds),
    do: {:error, reason}

  # A silent endpoint never reaches `into/2` -- it exhausts the attempt timeout
  # instead. Once the deadline has passed, that is the deadline being reported,
  # and saying so points at the endpoint rather than at one lost packet.
  defp unwrap({:error, %Req.TransportError{reason: :timeout}} = result, bounds) do
    if remaining(bounds) <= 0, do: {:error, :inference_deadline_exceeded}, else: result
  end

  defp unwrap(result, _bounds), do: result

  # Req's `:retry` option takes a mode or a function, never both, so the modes
  # this client uses are restated here with the deadline folded in: a retry is
  # only worth starting while a whole attempt still fits before it.
  defp retry_fun(bounds, mode) do
    fn request, response_or_exception ->
      retry?(mode, request, response_or_exception) and
        remaining(bounds) >= bounds.attempt_timeout
    end
  end

  defp retry?(:transient, _request, response_or_exception),
    do: transient?(response_or_exception)

  defp retry?(:safe_transient, request, response_or_exception),
    do: request.method in [:get, :head] and transient?(response_or_exception)

  defp retry?(false, _request, _response_or_exception), do: false

  defp transient?(%Req.Response{status: status}) when status in [408, 429, 500, 502, 503, 504],
    do: true

  defp transient?(%Req.Response{}), do: false

  defp transient?(%Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed],
       do: true

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: true

  defp transient?(_response_or_exception), do: false
end
