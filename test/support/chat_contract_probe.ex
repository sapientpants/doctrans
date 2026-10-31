defmodule Doctrans.Chat.ContractProbe do
  @moduledoc """
  A scripted model and query-dependent embedder that records the inputs chat
  actually sends.

  Start it with the owner to report to, the embedding each query answers with
  and the chat responses in the order they are consumed, then `install/1` it
  on the OpenAI and embedding mocks for the running test:

      probe = start_supervised!({ContractProbe, %{owner: self(), embeddings: ..., chat_responses: [...]}})
      ContractProbe.install(probe)
  """

  use Agent

  import Mox

  alias Doctrans.Processing.OpenAIMock
  alias Doctrans.Search.EmbeddingMock

  def start_link(state) do
    Agent.start_link(fn -> Map.merge(%{chat_responses: [], embeddings: %{}}, state) end)
  end

  @doc """
  Routes the running test's chat calls through `probe`, and its embedding calls
  too when the probe was started with scripted embeddings. Without any, the
  default embedding stub keeps answering.
  """
  def install(probe) do
    stub(OpenAIMock, :chat, fn messages, opts -> chat(probe, messages, opts) end)

    stub(OpenAIMock, :chat_stream, fn messages, on_delta, opts ->
      chat_stream(probe, messages, on_delta, opts)
    end)

    if Agent.get(probe, &(&1.embeddings != %{})) do
      stub(EmbeddingMock, :generate, fn query, opts -> generate(probe, query, opts) end)
    end

    :ok
  end

  def chat(probe, messages, opts) do
    Agent.get_and_update(probe, fn %{chat_responses: [response | rest]} = state ->
      send(state.owner, {:contract_chat, messages, opts})
      {response, %{state | chat_responses: rest}}
    end)
  end

  def chat_stream(probe, messages, on_delta, opts) do
    owner = Agent.get(probe, & &1.owner)
    send(owner, {:contract_generation, messages, opts})
    on_delta.("Answer.")
    {:ok, "Answer."}
  end

  def generate(probe, query, _opts) do
    Agent.get(probe, fn state ->
      send(state.owner, {:contract_embedding, query})
      {:ok, Map.fetch!(state.embeddings, query)}
    end)
  end

  def remaining_responses(probe), do: Agent.get(probe, & &1.chat_responses)
end
