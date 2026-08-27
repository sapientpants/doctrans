defmodule Doctrans.Chat.QueryExpander do
  @moduledoc """
  Plans document retrieval by turning a user message into a set of targeted
  vector-store search queries.

  In a single LLM call it:
  1. Understands + reformulates the latest message into a standalone question
     using chat history (critical for follow-ups like "tell me more about that").
  2. Decomposes the request into multiple concrete sub-queries that each retrieve
     a distinct piece of the information needed to answer — for analytical or
     assessment questions ("assess the balance sheet"), the component facts
     (assets, equity, liabilities, liquidity, debt, trends), not mere synonyms.

  Runs on every turn (including the first). The returned queries are fed to
  `Doctrans.Chat.MultiSearch`, which searches them in parallel and fuses results
  via RRF.
  """

  alias Doctrans.Chat.LineParser

  require Logger

  @max_predict 512
  @max_queries 6

  @doc """
  Plans the retrieval queries for `question`.

  Returns `{standalone_question, queries}` where `standalone_question` is the
  reformulated question and `queries` is the standalone plus targeted sub-queries
  (deduped, capped at #{@max_queries}).

  On any LLM failure, gracefully falls back to `{question, [question]}`.
  """
  def expand(question, chat_history, opts \\ [])

  def expand(question, chat_history, opts) do
    prompt = build_prompt(question, chat_history)
    messages = [%{role: "user", content: prompt}]

    case openai_module().chat(messages, chat_opts(opts)) do
      {:ok, response} ->
        Logger.debug("Query planner raw response:\n#{String.slice(response, 0, 500)}")
        parse_plan(response, question)

      {:error, reason} ->
        Logger.warning("Query planning failed, using original query: #{inspect(reason)}")
        {question, [question]}
    end
  end

  defp build_prompt(question, []) do
    """
    Understand the user's question about a document, then plan how to retrieve the
    information needed to answer it thoroughly.

    Do the following:
    1. Restate the question as a clear standalone question.
    2. Break it into up to 5 targeted search queries, each retrieving a distinct
       piece of information needed to answer. For analytical or assessment
       questions, decompose into the specific facts and figures required (for a
       balance-sheet assessment: total assets, equity, liabilities, liquidity/cash,
       debt, year-over-year changes) rather than rephrasings of the same query.

    User's question: #{question}

    Respond in exactly this format with no other text:
    Standalone: <standalone question>
    Query 1: <targeted search query>
    Query 2: <targeted search query>
    Query 3: <targeted search query>
    Query 4: <targeted search query>
    Query 5: <targeted search query>
    """
  end

  defp build_prompt(question, chat_history) do
    """
    Understand the user's latest message in the conversation, then plan how to
    retrieve the information needed to answer it thoroughly.

    Do the following:
    1. Rewrite the latest message as a standalone question with full context from
       the conversation.
    2. Break it into up to 5 targeted search queries, each retrieving a distinct
       piece of information needed to answer. For analytical or assessment
       questions, decompose into the specific facts and figures required (for a
       balance-sheet assessment: total assets, equity, liabilities, liquidity/cash,
       debt, year-over-year changes) rather than rephrasings of the same query.

    Conversation:
    #{format_history(chat_history)}

    User's message: #{question}

    Respond in exactly this format with no other text:
    Standalone: <standalone question>
    Query 1: <targeted search query>
    Query 2: <targeted search query>
    Query 3: <targeted search query>
    Query 4: <targeted search query>
    Query 5: <targeted search query>
    """
  end

  defp parse_plan(response, original_question) do
    lines = LineParser.lines(response)

    standalone = LineParser.extract_field(lines, "Standalone:")
    standalone_q = standalone || original_question

    sub_queries =
      1..5
      |> Enum.map(fn i -> LineParser.extract_field(lines, "Query #{i}:") end)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    queries =
      [standalone_q | sub_queries]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()
      |> Enum.take(@max_queries)

    queries = if queries == [], do: [original_question], else: queries

    Logger.info(
      "Query plan: #{length(queries)} queries from \"#{String.slice(original_question, 0, 80)}\"" <>
        "\n  Standalone: #{standalone_q}" <>
        Enum.map_join(queries, "", fn q -> "\n  Query: #{q}" end)
    )

    {standalone_q, queries}
  end

  defp format_history(chat_history) do
    chat_history
    |> Enum.take(-4)
    |> Enum.map_join("\n", fn msg ->
      role = if msg.role == "user", do: "User", else: "Assistant"
      "#{role}: #{msg.content}"
    end)
  end

  defp chat_opts(opts) do
    model = Keyword.get(opts, :model)
    # Query planning is a structured transform, not a reasoning task; disable
    # thinking so the max_tokens budget is not consumed producing an empty
    # (thinking-only) response.
    base = [max_tokens: @max_predict, think: false]
    if model, do: Keyword.put(base, :model, model), else: base
  end

  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end
end
