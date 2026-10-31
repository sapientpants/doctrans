defmodule Doctrans.Search.EmbeddingStub do
  @moduledoc """
  The default `Doctrans.Search.EmbeddingBehaviour` stub.

  Returns a fake embedding vector, so tests exercise the search code paths
  without the embedding service. `Doctrans.Mocks.setup/1` installs it on
  `Doctrans.Search.EmbeddingMock` for every test; a test that needs a failure,
  a held call or a record of what was embedded narrows the mock with
  `Doctrans.Search.EmbeddingMocks`.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  @doc """
  Returns a fake 1024-dimensional embedding vector, or `{:ok, nil}` for no text.
  """
  @impl true
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}

  def generate(_text, _opts) do
    # Same width as a real embedding, and deterministic so results repeat.
    {:ok, Pgvector.new(List.duplicate(0.1, 1024))}
  end
end
