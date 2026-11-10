defmodule Doctrans.Processing.SSECollector do
  @moduledoc """
  Incremental parser for server-sent-event (`text/event-stream`) responses.

  Chunks of the raw body are fed in as they arrive; complete `data:` frames
  are parsed and their content deltas are emitted through the provided
  callback as soon as they are available. The buffer only ever holds the
  trailing incomplete line, so it stays small even for long responses.

  The collector also counts the content frames it has emitted, against a
  ceiling fixed in `new/2`. `Doctrans.Processing.RequestBounds` caps bytes and
  wall time, but not frames: a one-character delta costs under fifty bytes on
  the wire, so a byte budget of a few megabytes still admits well over a
  hundred thousand frames, and every one of them is a message to the caller and
  a render in the chat panel. A stream that crosses the ceiling is answered
  with `{:error, {:inference_response_too_fragmented, limit: frames}}` from
  the `feed/2` or `finish/1` that saw the frame past it, and nothing after that
  frame reaches the callback. An honest answer sits far below the ceiling,
  since a model emits at most one frame per token.
  """

  alias Doctrans.Config.OpenAI

  @typedoc """
  Collector state: the delta callback, the trailing partial line, deltas in
  reverse order, and the frames emitted so far against the ceiling.
  """
  @type t :: %__MODULE__{
          on_delta: (String.t() -> any()),
          buffer: String.t(),
          content: [String.t()],
          frames: non_neg_integer(),
          max_frames: pos_integer()
        }

  @enforce_keys [:on_delta, :max_frames]
  defstruct on_delta: nil, buffer: "", content: [], frames: 0, max_frames: nil

  @typedoc "The one failure the collector produces: more content frames than the ceiling."
  @type error :: {:inference_response_too_fragmented, [limit: pos_integer()]}

  @doc """
  Creates a collector that invokes `on_delta/1` for each content delta.

  ## Options

  - `:max_response_frames` - how many content frames one response may carry (default:
    `Doctrans.Config.OpenAI.max_response_frames/0`)
  """
  @spec new((String.t() -> any()), keyword()) :: t()
  def new(on_delta, opts \\ []) do
    %__MODULE__{
      on_delta: on_delta,
      max_frames: Keyword.get(opts, :max_response_frames) || OpenAI.max_response_frames()
    }
  end

  @doc """
  Feeds a raw chunk into the collector, emitting any completed frames.

  Returns the error, not a state, once the frame past the ceiling has been
  parsed: the frames before it were emitted and are kept, the one past it is
  dropped with the rest of the chunk, and there is no state to feed further.
  """
  @spec feed(t(), binary()) :: {:ok, t()} | {:error, error()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    parts = :binary.split(state.buffer <> chunk, "\n", [:global])

    emit_lines(%{state | buffer: List.last(parts)}, Enum.drop(parts, -1))
  end

  @doc """
  Flushes any trailing line and joins the accumulated deltas in order.

  A trailing line is one more frame, so it is the one place the ceiling can
  still trip after the last `feed/2` passed.
  """
  @spec finish(t()) :: {:ok, String.t()} | {:error, error()}
  def finish(%__MODULE__{} = state) do
    with {:ok, state} <- emit_line(state.buffer, state) do
      {:ok, state.content |> Enum.reverse() |> :erlang.iolist_to_binary()}
    end
  end

  defp emit_lines(state, lines) do
    Enum.reduce_while(lines, {:ok, state}, fn line, {:ok, state} ->
      case emit_line(line, state) do
        {:ok, _state} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp emit_line(line, state) do
    line =
      try do
        String.trim(line)
      rescue
        _ -> ""
      end

    if data_frame?(line) do
      payload = line |> String.trim_leading("data:") |> String.trim()

      case Jason.decode(payload) do
        {:ok, %{"choices" => [%{"delta" => %{"content" => content}}]}}
        when is_binary(content) and content != "" ->
          emit_content(content, state)

        _ ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  # The check runs before the callback, so the frame past the ceiling is
  # neither emitted nor kept.
  defp emit_content(_content, %__MODULE__{frames: frames, max_frames: max_frames})
       when frames >= max_frames,
       do: {:error, {:inference_response_too_fragmented, limit: max_frames}}

  defp emit_content(content, state) do
    state.on_delta.(content)
    {:ok, %{state | content: [content | state.content], frames: state.frames + 1}}
  end

  defp data_frame?(line) do
    line != "data: [DONE]" and String.starts_with?(line, "data:")
  end
end
