defmodule Doctrans.Chat.GraderTest do
  # Each test scripts the model's reply on the OpenAI mock for itself, so the
  # file needs neither the database nor any global state.
  use Doctrans.EnvCase, async: true

  alias Doctrans.Chat.Grader
  alias Doctrans.Processing.OpenAIMock

  describe "grade/3" do
    test "empty context is graded insufficient without querying the model" do
      owner = self()

      Mox.stub(OpenAIMock, :chat, fn _messages, _opts ->
        send(owner, :model_queried)
        {:ok, ""}
      end)

      assert {:ok, %{sufficient: false, refined_queries: []}} =
               Grader.grade("What is the capital?", "")

      refute_received :model_queried
    end

    test "parses a sufficient verdict" do
      respond_with("Sufficient: yes")

      assert {:ok, %{sufficient: true, refined_queries: []}} =
               Grader.grade("What is the capital?", "[Page 1] Paris is the capital.")
    end

    test "parses an insufficient verdict with refined queries" do
      response = """
      Sufficient: no
      Query 1: population of the capital city
      Query 2: capital city demographics
      """

      respond_with(response)

      assert {:ok, grade} = Grader.grade("How many people live there?", "[Page 1] Some text.")
      refute grade.sufficient

      assert grade.refined_queries == [
               "population of the capital city",
               "capital city demographics"
             ]
    end

    test "defaults to sufficient when the response has no recognizable verdict" do
      respond_with("some unrelated text")

      assert {:ok, %{sufficient: true}} =
               Grader.grade("Question?", "[Page 1] Context.")
    end

    test "falls back to sufficient on model error" do
      respond_with({:error, :timeout})

      assert {:ok, %{sufficient: true, refined_queries: []}} =
               Grader.grade("Question?", "[Page 1] Context.")
    end
  end

  # Scripts `chat/2`'s reply: a binary is returned as a success, a tuple as is.
  defp respond_with({:error, _reason} = error) do
    Mox.stub(OpenAIMock, :chat, fn _messages, _opts -> error end)
  end

  defp respond_with(response) when is_binary(response) do
    Mox.stub(OpenAIMock, :chat, fn _messages, _opts -> {:ok, response} end)
  end
end
