defmodule Doctrans.Chat.QueryExpanderTest do
  use Doctrans.EnvCase, async: false

  alias Doctrans.Chat.{ContractProbe, QueryExpander}
  alias Doctrans.TestEnv

  describe "expand/3" do
    test "plans multiple targeted queries even without chat history" do
      response = """
      Standalone: What is the assessed quality of the balance sheet?
      Query 1: total assets and equity
      Query 2: total liabilities and debt
      Query 3: cash and liquidity
      """

      respond_with({:ok, response})

      {standalone, queries} =
        QueryExpander.expand("assess the balance sheet", [])

      assert standalone == "What is the assessed quality of the balance sheet?"

      assert queries == [
               standalone,
               "total assets and equity",
               "total liabilities and debt",
               "cash and liquidity"
             ]

      assert_received {:contract_chat, [%{role: "user", content: prompt}], _}
      assert prompt =~ "User's question: assess the balance sheet"
    end

    test "reformulates using chat history and plans sub-queries" do
      history = [
        %{role: "user", content: "Old topic outside the history window"},
        %{role: "assistant", content: "Old answer outside the history window"},
        %{role: "user", content: "Describe the report."},
        %{role: "assistant", content: "It is about our research."},
        %{role: "user", content: "What are the main themes?"},
        %{role: "assistant", content: "The main themes are X, Y, and Z."}
      ]

      response = """
      Standalone: Tell me more about theme Y.
      Query 1: details about Y
      Query 2: examples of Y
      """

      respond_with({:ok, response})

      {standalone, queries} = QueryExpander.expand("Tell me more about Y", history)

      assert standalone == "Tell me more about theme Y."
      assert queries == [standalone, "details about Y", "examples of Y"]

      assert_received {:contract_chat, [%{role: "user", content: prompt}], _}

      assert prompt =~
               "User: Describe the report.\nAssistant: It is about our research.\nUser: What are the main themes?\nAssistant: The main themes are X, Y, and Z."

      assert prompt =~ "User's message: Tell me more about Y"
      refute prompt =~ "Old topic outside the history window"
      refute prompt =~ "Old answer outside the history window"
    end

    test "caps the number of queries" do
      response = """
      Standalone: q0
      Query 1: q1
      Query 2: q2
      Query 3: q3
      Query 4: q4
      Query 5: q5
      Query 6: q6
      Query 7: q7
      """

      respond_with({:ok, response})

      {_standalone, queries} = QueryExpander.expand("something", [])

      assert queries == ["q0", "q1", "q2", "q3", "q4", "q5"]
    end

    test "removes duplicate and empty sub-queries without dropping the standalone question" do
      respond_with(
        {:ok,
         """
         Standalone: shared question
         Query 1: shared question
         Query 2:
         Query 3: another fact
         Query 4: another fact
         """}
      )

      assert QueryExpander.expand("original question", []) ==
               {"shared question", ["shared question", "another fact"]}
    end

    test "falls back to the original question on LLM error" do
      respond_with({:error, :timeout})

      {standalone, queries} = QueryExpander.expand("What about chapter 2?", [])

      assert standalone == "What about chapter 2?"
      assert queries == ["What about chapter 2?"]
    end
  end

  defp respond_with(response) do
    probe = start_supervised!({ContractProbe, %{owner: self(), chat_responses: [response]}})
    TestEnv.put_env(:chat_contract_probe, probe)
    TestEnv.put_env(:openai_module, ContractProbe)
  end
end
