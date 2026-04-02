defmodule Doctrans.Chat.QueryExpanderTest do
  use ExUnit.Case, async: false

  alias Doctrans.Chat.QueryExpander

  describe "expand/3" do
    test "returns original question with no chat history" do
      {standalone, queries} = QueryExpander.expand("What is this book about?", [])

      assert standalone == "What is this book about?"
      assert queries == ["What is this book about?"]
    end

    test "calls LLM when chat history exists" do
      history = [
        %{role: "user", content: "What are the main themes?"},
        %{role: "assistant", content: "The main themes are X, Y, and Z."}
      ]

      # The OllamaStub returns a generic response that won't match the expected format,
      # so QueryExpander should fall back to the original question as standalone
      {standalone, queries} = QueryExpander.expand("Tell me more about Y", history)

      assert is_binary(standalone)
      assert queries != []
    end

    test "falls back to original question on LLM error" do
      history = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there"}
      ]

      Application.put_env(:doctrans, :ollama_stub_chat_error, "timeout")

      {standalone, queries} = QueryExpander.expand("What about chapter 2?", history)

      assert standalone == "What about chapter 2?"
      assert queries == ["What about chapter 2?"]
    after
      Application.delete_env(:doctrans, :ollama_stub_chat_error)
    end

    test "returns empty history same as no expansion" do
      {standalone, queries} = QueryExpander.expand("Simple question", [])

      assert standalone == "Simple question"
      assert queries == ["Simple question"]
    end
  end
end
