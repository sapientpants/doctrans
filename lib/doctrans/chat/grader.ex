defmodule Doctrans.Chat.Grader do
  @moduledoc """
  Assesses whether retrieved context is sufficient to answer a question.

  This is the "assess" step of the agentic RAG pipeline: after retrieval, a
  cheap LLM call grades whether the context actually contains enough information
  to answer the user's question. When it does not, the grader proposes refined
  search queries so the agent can retrieve again.

  On any LLM or parsing failure, it degrades gracefully to
  `%{sufficient: true, refined_queries: []}` so chat never breaks — this
  reproduces the pre-agent behavior of answering with whatever was retrieved.
  """

  alias Doctrans.Chat.LineParser

  require Logger

  @grade_timeout 30_000
  @max_predict 256

  @doc """
  Grades whether `context` is sufficient to answer `question`.

  Returns `{:ok, %{sufficient: boolean(), refined_queries: [String.t()]}}`.
  Always returns `{:ok, _}` — failures fall back to a "sufficient" verdict.
  """
  def grade(question, context, opts \\ [])

  def grade(_question, "", _opts) do
    # No context at all — nothing to grade against and nothing to refine toward.
    {:ok, %{sufficient: false, refined_queries: []}}
  end

  def grade(question, context, opts) do
    prompt = """
    You are assessing whether the CONTEXT below contains enough information to
    answer the QUESTION. Do not answer the question yourself.

    QUESTION: #{question}

    CONTEXT:
    #{context}

    Respond in exactly this format with no other text:
    Sufficient: <yes or no>
    Query 1: <a better search query, only if not sufficient>
    Query 2: <another better search query, only if not sufficient>
    """

    messages = [%{role: "user", content: prompt}]

    case openai_module().chat(messages, chat_opts(opts)) do
      {:ok, response} ->
        Logger.debug("Grader raw response:\n#{String.slice(response, 0, 300)}")
        {:ok, parse_grade(response)}

      {:error, reason} ->
        Logger.warning("Grading failed, assuming context is sufficient: #{inspect(reason)}")
        {:ok, %{sufficient: true, refined_queries: []}}
    end
  end

  defp parse_grade(response) do
    lines = LineParser.lines(response)

    sufficient? =
      case LineParser.extract_field(lines, "Sufficient:") do
        nil -> true
        value -> String.downcase(value) |> String.starts_with?("yes")
      end

    refined_queries =
      [LineParser.extract_field(lines, "Query 1:"), LineParser.extract_field(lines, "Query 2:")]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    %{sufficient: sufficient?, refined_queries: refined_queries}
  end

  defp chat_opts(opts) do
    model = Keyword.get(opts, :model)
    # Grading is a structured classification, not a reasoning task; disable
    # thinking so the small max_tokens budget produces the verdict, not an
    # empty (thinking-only) response.
    base = [timeout: @grade_timeout, max_tokens: @max_predict, think: false]
    if model, do: Keyword.put(base, :model, model), else: base
  end

  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end
end
