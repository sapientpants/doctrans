defmodule Doctrans.Chat.QueryExpander do
  @moduledoc """
  Expands user queries for improved RAG retrieval.

  Performs two tasks in a single LLM call:
  1. Contextual reformulation - rewrites the user's message as a standalone question
     using chat history (critical for follow-up questions like "tell me more about that")
  2. Multi-query expansion - generates alternative phrasings to catch vocabulary mismatches
  """

  require Logger

  @expansion_timeout 30_000
  @max_predict 256

  @doc """
  Expands a user question into multiple search queries.

  When chat history is present, reformulates the question to be standalone and generates
  alternative phrasings. When there's no history, returns the original question as the
  standalone question and only query.

  Returns `{standalone_question, queries}` where `standalone_question` is the reformulated
  question (or the original if no history) and `queries` is a list of query variants to
  search with.

  On any LLM failure, gracefully falls back to `{question, [question]}`.
  """
  def expand(question, chat_history, opts \\ [])

  def expand(question, [], _opts) do
    {question, [question]}
  end

  def expand(question, chat_history, opts) do
    history_text = format_history(chat_history)

    prompt = """
    Given the conversation and the user's latest message, do the following:
    1. Rewrite the message as a standalone question with full context from the conversation
    2. Generate 2 alternative phrasings that use different words but preserve the meaning

    Conversation:
    #{history_text}

    User's message: #{question}

    Respond in exactly this format with no other text:
    Standalone: <rewritten question>
    Alt 1: <alternative phrasing>
    Alt 2: <alternative phrasing>
    """

    messages = [%{role: "user", content: prompt}]

    case ollama_module().chat(messages, chat_opts(opts)) do
      {:ok, response} ->
        Logger.debug("Query expansion raw response:\n#{String.slice(response, 0, 500)}")
        parse_expansion(response, question)

      {:error, reason} ->
        Logger.warning("Query expansion failed, using original query: #{inspect(reason)}")
        {question, [question]}
    end
  end

  defp parse_expansion(response, original_question) do
    lines =
      response
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    standalone = extract_field(lines, "Standalone:")
    alt1 = extract_field(lines, "Alt 1:")
    alt2 = extract_field(lines, "Alt 2:")

    standalone_q = standalone || original_question

    queries =
      [standalone_q, alt1, alt2]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    queries = if queries == [], do: [original_question], else: queries

    Logger.info(
      "Query expansion: #{length(queries)} variants from \"#{String.slice(original_question, 0, 80)}\"" <>
        "\n  Standalone: #{standalone_q}" <>
        Enum.map_join(queries, "", fn q -> "\n  Query: #{q}" end)
    )

    {standalone_q, queries}
  end

  defp extract_field(lines, prefix) do
    case Enum.find(lines, &String.starts_with?(&1, prefix)) do
      nil -> nil
      line -> line |> String.replace_prefix(prefix, "") |> String.trim()
    end
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
    base = [timeout: @expansion_timeout, num_predict: @max_predict]
    if model, do: Keyword.put(base, :model, model), else: base
  end

  defp ollama_module do
    Application.get_env(:doctrans, :ollama_module, Doctrans.Processing.Ollama)
  end
end
