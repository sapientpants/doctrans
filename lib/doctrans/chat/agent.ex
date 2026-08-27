defmodule Doctrans.Chat.Agent do
  @moduledoc """
  Agentic RAG pipeline for document chat.

  Runs understand → retrieve → merge → assess → generate on every turn, streaming
  the final answer token-by-token. The document is **always** searched, and the
  retrieved chunks accumulate into a running, deduped per-conversation context
  (passed in via `opts[:retrieved_context]` and returned for the next turn). This
  guarantees the source is searched whenever the conversation lacks the answer,
  and keeps the real retrieved chunks — not just paraphrased prior answers — in
  front of the model across turns.

  Progress and streamed tokens are reported through an `on_event` callback so the
  caller (a LiveView) can render stage labels and stream the answer. Events:

    * `{:stage, stage}` — `:understanding | :retrieving | :assessing | :generating`
    * `{:delta, text}`  — a chunk of the streamed answer

  Understanding decomposes the request into several targeted vector-store queries
  (`Doctrans.Chat.QueryExpander`); the grader (`Doctrans.Chat.Grader`) can then
  drive up to `@max_refine_rounds` additional search rounds to gather whatever is
  still missing before generating.
  """

  alias Doctrans.Chat
  alias Doctrans.Chat.{Grader, QueryExpander}

  require Logger

  # Extra retrieval rounds the grader may trigger when context is insufficient
  # (on top of the initial planned multi-query search).
  @max_refine_rounds 2

  @doc """
  Runs the agentic chat pipeline for `question` against `document`.

  `on_event` is a 1-arity function invoked with progress and streaming events
  (see the module doc). `opts[:retrieved_context]` carries the accumulated context
  from prior turns (default `[]`).

  Returns `{:ok, full_answer, merged_context}` or `{:error, reason}`, where
  `merged_context` is the updated accumulated context to feed into the next turn.
  """
  def run(document, question, chat_history \\ [], opts \\ [], on_event)

  def run(_document, question, _chat_history, _opts, _on_event)
      when question in [nil, ""] do
    {:error, :empty_question}
  end

  def run(document, question, chat_history, opts, on_event) when is_function(on_event, 1) do
    trimmed_question = String.trim(question)

    if trimmed_question == "" do
      {:error, :empty_question}
    else
      do_run(document, trimmed_question, chat_history, opts, on_event)
    end
  end

  defp do_run(document, question, chat_history, opts, on_event) do
    context_limit = Keyword.get(opts, :context_limit, 8)
    min_similarity = Keyword.get(opts, :min_similarity)
    prior_context = Keyword.get(opts, :retrieved_context, [])

    search_opts =
      [limit: context_limit]
      |> then(fn o ->
        if min_similarity, do: Keyword.put(o, :min_similarity, min_similarity), else: o
      end)

    Logger.info(
      "Agent processing question for document #{document.id}: #{String.slice(question, 0, 100)}"
    )

    # 1. Understand: reformulate + expand into query variants
    on_event.({:stage, :understanding})
    {standalone_question, queries} = QueryExpander.expand(question, chat_history, opts)

    # 2. Retrieve (always search the document)
    on_event.({:stage, :retrieving})

    case Chat.retrieve(document.id, standalone_question, queries, search_opts) do
      {:ok, pages} ->
        # 3. Merge new chunks into the accumulated context (dedup + cap)
        merged = Chat.merge_context(prior_context, pages)

        # 4. Assess the merged context; search once more if it is insufficient
        on_event.({:stage, :assessing})
        merged = assess_and_maybe_refine(document, merged, standalone_question, search_opts, opts)

        # 5. Generate (streamed)
        on_event.({:stage, :generating})

        case generate(document, merged, chat_history, standalone_question, opts, on_event) do
          {:ok, response} -> {:ok, response, merged}
          {:error, _reason} = error -> error
        end

      {:error, reason} = error ->
        Logger.error("Agent retrieval failed for document #{document.id}: #{inspect(reason)}")
        error
    end
  end

  # Iteratively grades the merged context and, while it is insufficient and the
  # grader proposes refined queries, searches again and folds the results in.
  # Bounded to @max_refine_rounds extra rounds so we gather more data without
  # looping forever. Returns the final merged chunk list.
  defp assess_and_maybe_refine(document, merged, standalone_question, search_opts, opts) do
    refine(document, merged, standalone_question, search_opts, opts, @max_refine_rounds)
  end

  defp refine(_document, merged, _standalone_question, _search_opts, _opts, 0), do: merged

  defp refine(document, merged, standalone_question, search_opts, opts, rounds_left) do
    context_text = Chat.build_context(merged)
    {:ok, grade} = Grader.grade(standalone_question, context_text, opts)

    if grade.sufficient or grade.refined_queries == [] do
      merged
    else
      Logger.info(
        "Context graded insufficient; searching again with #{length(grade.refined_queries)} refined queries (#{rounds_left} round(s) left)"
      )

      case Chat.retrieve(document.id, standalone_question, grade.refined_queries, search_opts) do
        {:ok, refined_pages} ->
          merged
          |> Chat.merge_context(refined_pages)
          |> then(&refine(document, &1, standalone_question, search_opts, opts, rounds_left - 1))

        {:error, reason} ->
          Logger.warning("Refined retrieval failed, keeping current context: #{inspect(reason)}")
          merged
      end
    end
  end

  defp generate(document, merged, chat_history, standalone_question, opts, on_event) do
    context_text = Chat.build_context(merged)
    system_prompt = Chat.build_system_prompt(document.title, context_text)
    messages = Chat.build_messages(system_prompt, chat_history, standalone_question)
    stream_answer(document, messages, opts, on_event)
  end

  defp stream_answer(document, messages, opts, on_event) do
    on_delta = fn delta -> on_event.({:delta, delta}) end

    case openai_module().chat_stream(messages, on_delta, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Agent generation failed for document #{document.id}: #{inspect(reason)}")
        error
    end
  end

  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end
end
