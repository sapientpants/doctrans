defmodule Doctrans.Processing.OpenAIBoundsTest do
  @moduledoc """
  Tests the bounds around the inference client: a total deadline that
  covers Req's retries, and a response size cap, on the non-streaming completion
  path and on the streaming one.

  The misbehaving endpoints are raw TCP servers rather than Bypass, because each
  of them deliberately outlives the call it is answering -- it stalls, drips, or
  floods -- and a plug server cannot be shut down cleanly underneath one. The
  budgets are configured down to milliseconds and kilobytes so the suite spends
  no longer proving this than it has to.

  `async: false`: the `:doctrans` application environment is mutated and
  restored, and the `:openai_api` fuse is shared.
  """
  use ExUnit.Case, async: false

  # A cut-off endpoint is an error path, and `ApiFailure` logs every one of them.
  @moduletag :capture_log

  alias Doctrans.Processing.OpenAI
  alias Doctrans.Resilience.{CircuitBreaker, ErrorClassifier}
  alias DoctransWeb.ErrorMessages

  # Small enough that a misbehaving endpoint is caught in well under a second,
  # large enough that a connect and a JSON round trip do not trip it.
  @deadline 300
  @max_bytes 100_000
  # The wall clock a bounded call must finish inside: five times the deadline, so
  # the assertion catches an unbounded call rather than a slow machine.
  @bounded_ms 1_500

  # 20 MB offered 64 KiB at a time, against a 100 KB cap. The client halts on the
  # second chunk; what the endpoint gets to push after that is whatever fits in
  # the socket buffers, which is orders of magnitude below what it offered.
  @flood_chunks 320
  @flood_chunk_bytes 64 * 1024
  @buffered_chunks_allowed 64

  setup do
    CircuitBreaker.reset(:openai_api)
    previous = Application.get_env(:doctrans, :openai)

    on_exit(fn ->
      CircuitBreaker.reset(:openai_api)

      if previous,
        do: Application.put_env(:doctrans, :openai, previous),
        else: Application.delete_env(:doctrans, :openai)
    end)

    :ok
  end

  describe "total deadline" do
    test "a silent endpoint fails a completion inside the deadline" do
      start_endpoint(&stall/2)

      {elapsed, result} = call(fn -> OpenAI.chat([%{role: "user", content: "hi"}]) end)

      assert result == {:error, :inference_deadline_exceeded}
      assert elapsed < @bounded_ms
    end

    test "a silent endpoint fails a stream inside the deadline" do
      start_endpoint(&stall/2)

      {elapsed, result} = call(&stream/0)

      assert result == {:error, :inference_deadline_exceeded}
      assert elapsed < @bounded_ms
      refute_received {:delta, _}
    end

    test "a drip-feeding stream is cut off after the deltas it did deliver" do
      # One frame every 20 ms, forever as far as the client can tell. Each frame
      # resets `:receive_timeout`, so only a total deadline ends this.
      start_endpoint(&drip/2)

      {elapsed, result} = call(&stream/0)

      assert result == {:error, :inference_deadline_exceeded}
      assert elapsed < @bounded_ms
      # The stream was live when it was cut: this is a deadline being enforced,
      # not a failure to read the endpoint at all.
      assert_received {:delta, "tick"}
    end

    test "a drip-feeding completion is cut off inside the deadline" do
      start_endpoint(&drip/2)

      {elapsed, result} = call(fn -> OpenAI.chat([%{role: "user", content: "hi"}]) end)

      assert result == {:error, :inference_deadline_exceeded}
      assert elapsed < @bounded_ms
    end
  end

  describe "response size cap" do
    test "an oversized completion is refused before the body is buffered" do
      start_endpoint(&flood/2)

      {elapsed, result} = call(fn -> OpenAI.chat([%{role: "user", content: "hi"}]) end)

      assert result == {:error, {:inference_response_too_large, [limit: @max_bytes]}}
      assert elapsed < @bounded_ms
      assert_offered_but_not_read()
    end

    test "an oversized stream is refused before the body is buffered" do
      start_endpoint(&flood/2)

      {elapsed, result} = call(&stream/0)

      assert result == {:error, {:inference_response_too_large, [limit: @max_bytes]}}
      assert elapsed < @bounded_ms
      assert_offered_but_not_read()
    end

    test "a response inside the cap is returned as usual" do
      bypass = Bypass.open()
      configure(bypass.port)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "hello"}}]
          })
        )
      end)

      assert {:ok, "hello"} = OpenAI.chat([%{role: "user", content: "hi"}])
    end
  end

  describe "error reporting" do
    test "both bounds are classified and carry an actionable message" do
      assert ErrorClassifier.classify(:inference_deadline_exceeded) == :retryable
      assert ErrorClassifier.classify({:inference_response_too_large, limit: 1}) == :permanent

      assert ErrorMessages.message(:inference_deadline_exceeded) =~ "reprocess"

      message = ErrorMessages.message({:inference_response_too_large, limit: @max_bytes})
      assert message =~ to_string(@max_bytes)
      assert message =~ "try again"
    end
  end

  defp call(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  defp stream do
    OpenAI.chat_stream([%{role: "user", content: "hi"}], &send(self(), {:delta, &1}))
  end

  defp configure(port) do
    Application.put_env(:doctrans, :openai,
      base_url: "http://127.0.0.1:#{port}",
      api_key: nil,
      chat_model: "test-chat-model",
      vision_model: "test-vision-model",
      # Far above the deadline on purpose: bounding the call is the deadline's
      # job, and clamping the per-receive timeout to it is part of how it does
      # that.
      timeout: 60_000,
      deadline: @deadline,
      max_response_bytes: @max_bytes
    )
  end

  # Starts a one-connection endpoint that answers with `handler`, points the
  # client at it, and kills it when the test ends.
  defp start_endpoint(handler) do
    parent = self()

    server =
      spawn(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, nodelay: true])

        {:ok, port} = :inet.port(listen)
        send(parent, {:endpoint_port, port})
        {:ok, socket} = :gen_tcp.accept(listen)
        read_request(socket)
        handler.(socket, parent)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)

    receive do
      {:endpoint_port, port} -> configure(port)
    after
      5_000 -> flunk("fake endpoint did not start")
    end
  end

  # Reads up to the end of the request headers. The request body is left in the
  # socket buffer on purpose: none of these handlers cares what was asked.
  defp read_request(socket, acc \\ "") do
    case :binary.match(acc, "\r\n\r\n") do
      {_offset, 4} ->
        :ok

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          {:error, _reason} -> :ok
        end
    end
  end

  # Accepts the request and then says nothing at all, for as long as it is left
  # alive. This is the case a per-receive timeout does bound -- but once per
  # attempt, which is what the deadline exists to cap.
  defp stall(_socket, _parent), do: Process.sleep(:infinity)

  defp drip(socket, _parent) do
    :gen_tcp.send(socket, headers("text/event-stream"))
    drip_frames(socket)
  end

  defp drip_frames(socket) do
    frame =
      "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "tick"}}]}) <> "\n\n"

    case :gen_tcp.send(socket, chunk(frame)) do
      :ok ->
        Process.sleep(20)
        drip_frames(socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp flood(socket, parent) do
    :gen_tcp.send(socket, headers("application/json"))
    flood_chunks(socket, parent, @flood_chunks, :binary.copy("x", @flood_chunk_bytes))
  end

  defp flood_chunks(_socket, _parent, 0, _payload), do: :ok

  defp flood_chunks(socket, parent, remaining, payload) do
    case :gen_tcp.send(socket, chunk(payload)) do
      :ok ->
        send(parent, :chunk_sent)
        flood_chunks(socket, parent, remaining - 1, payload)

      {:error, _reason} ->
        :ok
    end
  end

  # The endpoint offered @flood_chunks; the client stopped reading at the cap, so
  # only what the socket buffers hold can have left the endpoint. Anything near
  # the full offer would mean the body was read before it was measured.
  defp assert_offered_but_not_read do
    assert drain_chunks_sent(0) < @buffered_chunks_allowed
  end

  defp drain_chunks_sent(count) do
    receive do
      :chunk_sent -> drain_chunks_sent(count + 1)
    after
      0 -> count
    end
  end

  defp headers(content_type) do
    "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n" <>
      "transfer-encoding: chunked\r\n\r\n"
  end

  defp chunk(data) do
    Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"
  end
end
