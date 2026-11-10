defmodule Doctrans.Processing.SSECollectorTest do
  use ExUnit.Case, async: true

  alias Doctrans.Config.OpenAI
  alias Doctrans.Processing.SSECollector

  test "reassembles a multibyte character and emits only complete lines" do
    frame = "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "hél"}}]})
    {offset, 2} = :binary.match(frame, "é")
    split = offset + 1
    <<first::binary-size(^split), rest::binary>> = frame
    collector = SSECollector.new(&send(self(), {:delta, &1}))

    {:ok, collector} = SSECollector.feed(collector, first)
    refute_received {:delta, _}
    {:ok, collector} = SSECollector.feed(collector, rest)
    refute_received {:delta, _}
    {:ok, collector} = SSECollector.feed(collector, "\n\n")
    assert_received {:delta, "hél"}

    {:ok, collector} = SSECollector.feed(collector, "data: [DONE]\n\n")
    assert SSECollector.finish(collector) == {:ok, "hél"}
    refute_received {:delta, _}
  end

  describe "the frame ceiling" do
    test "the frame past the ceiling fails the stream and is neither emitted nor kept" do
      collector = SSECollector.new(&send(self(), {:delta, &1}), max_response_frames: 2)

      {:ok, collector} = SSECollector.feed(collector, content_frame("a"))
      {:ok, collector} = SSECollector.feed(collector, content_frame("b"))

      assert SSECollector.feed(collector, content_frame("c") <> content_frame("d")) ==
               {:error, {:inference_response_too_fragmented, limit: 2}}

      assert_received {:delta, "a"}
      assert_received {:delta, "b"}
      refute_received {:delta, _}
    end

    test "a trailing frame past the ceiling fails finish/1 the same way" do
      collector = SSECollector.new(&send(self(), {:delta, &1}), max_response_frames: 1)

      {:ok, collector} = SSECollector.feed(collector, content_frame("a"))
      # No newline: the frame is still in the buffer when the stream ends.
      {:ok, collector} = SSECollector.feed(collector, String.trim_trailing(content_frame("b")))

      assert SSECollector.finish(collector) ==
               {:error, {:inference_response_too_fragmented, limit: 1}}

      assert_received {:delta, "a"}
      refute_received {:delta, _}
    end

    test "frames without content do not count" do
      collector = SSECollector.new(&send(self(), {:delta, &1}), max_response_frames: 1)

      role_only =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{"role" => "assistant"}}]}) <> "\n\n"

      empty =
        "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => ""}}]}) <> "\n\n"

      {:ok, collector} =
        SSECollector.feed(
          collector,
          role_only <> empty <> content_frame("a") <> "data: [DONE]\n\n"
        )

      assert SSECollector.finish(collector) == {:ok, "a"}
    end

    test "the default ceiling is the configured one" do
      limit = OpenAI.max_response_frames()
      collector = SSECollector.new(fn _ -> :ok end)
      within = String.duplicate(content_frame("a"), limit)

      {:ok, collector} = SSECollector.feed(collector, within)

      assert SSECollector.feed(collector, content_frame("b")) ==
               {:error, {:inference_response_too_fragmented, limit: limit}}
    end
  end

  defp content_frame(content) do
    "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => content}}]}) <> "\n\n"
  end
end
