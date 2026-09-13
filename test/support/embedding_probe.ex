defmodule Doctrans.Search.EmbeddingProbe do
  @moduledoc false

  @behaviour Doctrans.Search.EmbeddingBehaviour

  alias Doctrans.Search.EmbeddingStub

  @impl true
  def generate(query, opts \\ []) do
    case Application.get_env(:doctrans, :embedding_probe_pid) do
      pid when is_pid(pid) -> send(pid, {:embedded, query})
      _ -> :ok
    end

    EmbeddingStub.generate(query, opts)
  end
end
