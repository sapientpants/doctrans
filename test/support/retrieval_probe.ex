defmodule Doctrans.Chat.RetrievalProbe do
  @moduledoc false

  alias Doctrans.Search.EmbeddingStub

  def generate(query, opts) do
    send(Application.fetch_env!(:doctrans, :retrieval_probe_pid), {:embedded, query})
    EmbeddingStub.generate(query, opts)
  end

  def chat(messages, _opts) do
    content = messages |> List.last() |> Map.fetch!(:content)

    if String.contains?(content, "Sufficient:") do
      {:ok, "Sufficient: no\nQuery 1: liquidity and cash reserves"}
    else
      {:ok, "Standalone: assess the balance sheet"}
    end
  end

  def chat_stream(_messages, on_delta, _opts) do
    on_delta.("Answer.")
    {:ok, "Answer."}
  end
end
