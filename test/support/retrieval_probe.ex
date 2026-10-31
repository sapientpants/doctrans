defmodule Doctrans.Chat.RetrievalProbe do
  @moduledoc """
  A model that always asks for one more retrieval round, and an embedder that
  reports each query it is asked for as `{:embedded, query}`.
  """

  import Mox

  alias Doctrans.Processing.OpenAIMock
  alias Doctrans.Search.{EmbeddingMock, EmbeddingStub}

  @doc """
  Installs the probe on the OpenAI and embedding mocks for the running test.
  """
  def install do
    owner = self()

    stub(EmbeddingMock, :generate, fn query, opts ->
      send(owner, {:embedded, query})
      EmbeddingStub.generate(query, opts)
    end)

    stub(OpenAIMock, :chat, fn messages, _opts ->
      content = messages |> List.last() |> Map.fetch!(:content)

      if String.contains?(content, "Sufficient:") do
        {:ok, "Sufficient: no\nQuery 1: liquidity and cash reserves"}
      else
        {:ok, "Standalone: assess the balance sheet"}
      end
    end)

    stub(OpenAIMock, :chat_stream, fn _messages, on_delta, _opts ->
      on_delta.("Answer.")
      {:ok, "Answer."}
    end)

    :ok
  end
end
