defmodule Doctrans.Processing.SSECollectorTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.SSECollector

  test "reassembles a multibyte character and emits only complete lines" do
    frame = "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "hél"}}]})
    {offset, 2} = :binary.match(frame, "é")
    split = offset + 1
    <<first::binary-size(^split), rest::binary>> = frame
    collector = SSECollector.new(&send(self(), {:delta, &1}))

    collector = SSECollector.feed(collector, first)
    refute_received {:delta, _}
    collector = SSECollector.feed(collector, rest)
    refute_received {:delta, _}
    collector = SSECollector.feed(collector, "\n\n")
    assert_received {:delta, "hél"}

    collector = SSECollector.feed(collector, "data: [DONE]\n\n")
    assert SSECollector.finish(collector) == "hél"
    refute_received {:delta, _}
  end
end
