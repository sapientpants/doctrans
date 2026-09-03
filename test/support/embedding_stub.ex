defmodule Doctrans.Search.EmbeddingStub do
  @moduledoc """
  Stub implementation of EmbeddingBehaviour for tests.

  Returns a fake embedding vector that can be used in tests without
  requiring the actual OpenAI service.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  @doc """
  Returns a fake 1024-dimensional embedding vector.

  This allows tests to exercise the search code paths without
  requiring the actual embedding service.
  """
  @impl true
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}

  def generate(_text, _opts) do
    stub_delay()

    # Create a fake 1024-dimensional vector (same size as real embeddings)
    # Use deterministic values based on text hash for reproducibility
    fake_embedding = List.duplicate(0.1, 1024)
    {:ok, Pgvector.new(fake_embedding)}
  end

  # Optional artificial latency (via :embedding_stub_delay_ms) so tests can
  # hold a background task mid-embedding, e.g. to exercise deletion races.
  defp stub_delay do
    case Application.get_env(:doctrans, :embedding_stub_delay_ms) do
      ms when is_integer(ms) and ms > 0 ->
        Process.sleep(ms)

      _ ->
        :ok
    end
  end
end
