defmodule Doctrans.Processing.SSECollector do
  @moduledoc """
  Incremental parser for server-sent-event (`text/event-stream`) responses.

  Chunks of the raw body are fed in as they arrive; complete `data:` frames
  are parsed and their content deltas are emitted through the provided
  callback as soon as they are available. The buffer only ever holds the
  trailing incomplete line, so it stays small even for long responses.
  """

  @doc """
  Creates a collector that invokes `on_delta/1` for each content delta.
  """
  def new(on_delta) do
    %{on_delta: on_delta, buffer: "", content: []}
  end

  @doc """
  Feeds a raw chunk into the collector, emitting any completed frames.
  """
  def feed(state, chunk) when is_binary(chunk) do
    parts = :binary.split(state.buffer <> chunk, "\n", [:global])

    state
    |> Map.put(:buffer, List.last(parts))
    |> emit_lines(Enum.drop(parts, -1))
  end

  @doc """
  Flushes any trailing line and joins the accumulated deltas in order.
  """
  def finish(state) do
    state = emit_line(state.buffer, state)
    state.content |> Enum.reverse() |> :erlang.iolist_to_binary()
  end

  defp emit_lines(state, lines) do
    Enum.reduce(lines, state, &emit_line/2)
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
          state.on_delta.(content)
          %{state | content: [content | state.content]}

        _ ->
          state
      end
    else
      state
    end
  end

  defp data_frame?(line) do
    line != "data: [DONE]" and String.starts_with?(line, "data:")
  end
end
