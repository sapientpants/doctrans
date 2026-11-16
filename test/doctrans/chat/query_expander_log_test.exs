defmodule Doctrans.Chat.QueryExpanderLogTest do
  # Sync: `capture_info_log/1` raises the VM-wide `Logger` level for the
  # duration of a capture, which a concurrent test would see too. Only the
  # plan line is under test here; what the planner returns is
  # `Doctrans.Chat.QueryExpanderTest`'s.
  use Doctrans.EnvCase, async: false

  import ExUnit.CaptureLog

  alias Doctrans.Chat.{ContractProbe, QueryExpander}

  describe "the plan line" do
    test "slices a standalone question that falls back to a long user question" do
      question = String.duplicate("q", 1_000)
      respond_with({:ok, "Query 1: short query"})

      log = capture_info_log(fn -> QueryExpander.expand(question, []) end)

      assert log =~ "Standalone: " <> String.duplicate("q", 200)
      refute log =~ String.duplicate("q", 201)
    end

    test "slices every query the model replies with" do
      long_query = String.duplicate("y", 1_000)

      respond_with({:ok, "Standalone: #{String.duplicate("s", 1_000)}\nQuery 1: #{long_query}"})

      log = capture_info_log(fn -> QueryExpander.expand("short question", []) end)

      assert log =~ "Query: " <> String.duplicate("y", 200)
      refute log =~ String.duplicate("y", 201)
      refute log =~ String.duplicate("s", 201)
    end
  end

  defp respond_with(response) do
    probe = start_supervised!({ContractProbe, %{owner: self(), chat_responses: [response]}})
    ContractProbe.install(probe)
  end

  # The suite runs at :warning, so the plan line is only readable with the
  # level raised for the duration of the capture.
  defp capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
