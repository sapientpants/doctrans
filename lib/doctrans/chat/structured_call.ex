defmodule Doctrans.Chat.StructuredCall do
  @moduledoc """
  One chat completion whose reply is a fixed `Label: value` format, not prose.

  `Doctrans.Chat.QueryExpander` and `Doctrans.Chat.Grader` both make this kind of
  call: a single user prompt, a short deadline, a small token budget, and
  thinking disabled -- a structured transform is not a reasoning task, and with
  thinking on the budget would be spent on an empty (thinking-only) response
  rather than the lines the caller parses with `Doctrans.Chat.LineParser`.
  """

  alias Doctrans.Deps

  @timeout 30_000

  @doc """
  Sends `prompt` as the sole user message and returns the raw reply.

  `max_tokens` bounds the reply; a `:model` in `opts` overrides the configured
  chat model and anything else in `opts` is ignored.
  """
  @spec ask(String.t(), keyword(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def ask(prompt, opts, max_tokens) do
    Deps.openai().chat([%{role: "user", content: prompt}], chat_opts(opts, max_tokens))
  end

  defp chat_opts(opts, max_tokens) do
    base = [timeout: @timeout, max_tokens: max_tokens, think: false]

    case Keyword.get(opts, :model) do
      nil -> base
      model -> Keyword.put(base, :model, model)
    end
  end
end
