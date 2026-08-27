defmodule Doctrans.Chat.QueryExpanderTest do
  use ExUnit.Case, async: false

  alias Doctrans.Chat.QueryExpander

  # Test-only OpenAI module returning a planner response configured via :openai_stub_chat_error.
  defmodule FakeOpenAI do
    def chat(_messages, _opts) do
      case Application.get_env(:doctrans, :planner_fake_response) do
        {:error, reason} -> {:error, reason}
        response when is_binary(response) -> {:ok, response}
        _ -> {:ok, ""}
      end
    end
  end

  setup do
    original = Application.get_env(:doctrans, :openai_module)
    Application.put_env(:doctrans, :openai_module, FakeOpenAI)

    on_exit(fn ->
      Application.put_env(:doctrans, :openai_module, original)
      Application.delete_env(:doctrans, :planner_fake_response)
    end)

    :ok
  end

  describe "expand/3" do
    test "plans multiple targeted queries even without chat history" do
      response = """
      Standalone: What is the assessed quality of the balance sheet?
      Query 1: total assets and equity
      Query 2: total liabilities and debt
      Query 3: cash and liquidity
      """

      Application.put_env(:doctrans, :planner_fake_response, response)

      {standalone, queries} =
        QueryExpander.expand("assess the balance sheet", [])

      assert standalone == "What is the assessed quality of the balance sheet?"
      # Standalone + 3 decomposed sub-queries.
      assert length(queries) == 4
      assert "total liabilities and debt" in queries
      assert "cash and liquidity" in queries
    end

    test "reformulates using chat history and plans sub-queries" do
      history = [
        %{role: "user", content: "What are the main themes?"},
        %{role: "assistant", content: "The main themes are X, Y, and Z."}
      ]

      response = """
      Standalone: Tell me more about theme Y.
      Query 1: details about Y
      Query 2: examples of Y
      """

      Application.put_env(:doctrans, :planner_fake_response, response)

      {standalone, queries} = QueryExpander.expand("Tell me more about Y", history)

      assert standalone == "Tell me more about theme Y."
      assert length(queries) >= 2
    end

    test "caps the number of queries" do
      response = """
      Standalone: q0
      Query 1: q1
      Query 2: q2
      Query 3: q3
      Query 4: q4
      Query 5: q5
      """

      Application.put_env(:doctrans, :planner_fake_response, response)

      {_standalone, queries} = QueryExpander.expand("something", [])

      # Standalone + 5 sub-queries = 6, at the cap.
      assert length(queries) == 6
    end

    test "falls back to the original question on LLM error" do
      Application.put_env(:doctrans, :planner_fake_response, {:error, :timeout})

      {standalone, queries} = QueryExpander.expand("What about chapter 2?", [])

      assert standalone == "What about chapter 2?"
      assert queries == ["What about chapter 2?"]
    end
  end
end
