defmodule Doctrans.Search.EmbeddingErrorStub do
  @moduledoc """
  Embedding client that fails, so a test can drive the indexer's failure paths.

  `:embedding_error_reason` sets the failure returned, and defaults to a
  transient one. `:embedding_error_plan` narrows it to particular inputs: a list
  of `{matcher, reason}` pairs applied to the text in order, where a matcher is a
  substring, or a list of substrings that must all be present. Text that matches
  nothing in a plan succeeds through `Doctrans.Search.EmbeddingStub`, so a test
  can fail one chunk of a page and leave its neighbours alone — which is what
  separates "this page failed" from "this chunk failed". A list matcher reaches
  the page-level call specifically: it is the only one that sees the whole page's
  text at once, and so the only one carrying every chunk's marker.

  When `:embedding_call_observer` holds a pid, every call is reported to it as
  `{:embedding_call, text}`, so a test can assert which inputs were actually sent
  rather than inferring it from the outcome.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  alias Doctrans.Search.EmbeddingStub

  @impl true
  def generate(text, opts \\ []) do
    observe(text)

    case reason_for(text) do
      :ok -> EmbeddingStub.generate(text, opts)
      reason -> {:error, reason}
    end
  end

  defp reason_for(text) when is_binary(text) do
    case Application.get_env(:doctrans, :embedding_error_plan) do
      nil ->
        Application.get_env(:doctrans, :embedding_error_reason, :timeout)

      plan ->
        Enum.find_value(plan, :ok, fn {matcher, reason} ->
          matches?(text, matcher) && reason
        end)
    end
  end

  defp reason_for(_text), do: :ok

  defp matches?(text, substrings) when is_list(substrings),
    do: Enum.all?(substrings, &String.contains?(text, &1))

  defp matches?(text, substring), do: String.contains?(text, substring)

  defp observe(text) do
    case Application.get_env(:doctrans, :embedding_call_observer) do
      pid when is_pid(pid) -> send(pid, {:embedding_call, text})
      _ -> :ok
    end
  end
end
