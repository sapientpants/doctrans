defmodule Doctrans.Chat.GraderTest do
  use ExUnit.Case, async: false

  alias Doctrans.Chat.Grader

  # Test-only OpenAI module whose chat/2 returns a response configured via :openai_stub_chat_error.
  defmodule FakeOpenAI do
    def chat(_messages, _opts) do
      case Application.get_env(:doctrans, :grader_fake_response) do
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
      Application.delete_env(:doctrans, :grader_fake_response)
    end)

    :ok
  end

  describe "grade/3" do
    test "empty context is graded insufficient without querying the model" do
      assert {:ok, %{sufficient: false, refined_queries: []}} =
               Grader.grade("What is the capital?", "")
    end

    test "parses a sufficient verdict" do
      Application.put_env(:doctrans, :grader_fake_response, "Sufficient: yes")

      assert {:ok, %{sufficient: true, refined_queries: []}} =
               Grader.grade("What is the capital?", "[Page 1] Paris is the capital.")
    end

    test "parses an insufficient verdict with refined queries" do
      response = """
      Sufficient: no
      Query 1: population of the capital city
      Query 2: capital city demographics
      """

      Application.put_env(:doctrans, :grader_fake_response, response)

      assert {:ok, grade} = Grader.grade("How many people live there?", "[Page 1] Some text.")
      refute grade.sufficient

      assert grade.refined_queries == [
               "population of the capital city",
               "capital city demographics"
             ]
    end

    test "defaults to sufficient when the response has no recognizable verdict" do
      Application.put_env(:doctrans, :grader_fake_response, "some unrelated text")

      assert {:ok, %{sufficient: true}} =
               Grader.grade("Question?", "[Page 1] Context.")
    end

    test "falls back to sufficient on model error" do
      Application.put_env(:doctrans, :grader_fake_response, {:error, :timeout})

      assert {:ok, %{sufficient: true, refined_queries: []}} =
               Grader.grade("Question?", "[Page 1] Context.")
    end
  end
end
