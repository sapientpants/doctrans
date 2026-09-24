defmodule Doctrans.Chat.ContractProbe do
  @moduledoc "A scripted model and query-dependent embedder that records the inputs chat actually sends."
  use Agent

  def start_link(state) do
    Agent.start_link(fn -> Map.merge(%{chat_responses: [], embeddings: %{}}, state) end)
  end

  def chat(messages, opts) do
    Agent.get_and_update(probe(), fn %{chat_responses: [response | rest]} = state ->
      send(state.owner, {:contract_chat, messages, opts})
      {response, %{state | chat_responses: rest}}
    end)
  end

  def chat_stream(messages, on_delta, opts) do
    owner = Agent.get(probe(), & &1.owner)
    send(owner, {:contract_generation, messages, opts})
    on_delta.("Answer.")
    {:ok, "Answer."}
  end

  def generate(query, _opts) do
    Agent.get(probe(), fn state ->
      send(state.owner, {:contract_embedding, query})
      {:ok, Map.fetch!(state.embeddings, query)}
    end)
  end

  def remaining_responses(pid), do: Agent.get(pid, & &1.chat_responses)

  defp probe, do: Application.fetch_env!(:doctrans, :chat_contract_probe)
end
