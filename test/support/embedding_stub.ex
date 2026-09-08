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

  def generate(text, _opts) do
    await_barrier(text)

    # Create a fake 1024-dimensional vector (same size as real embeddings)
    # Use deterministic values based on text hash for reproducibility
    fake_embedding = List.duplicate(0.1, 1024)
    {:ok, Pgvector.new(fake_embedding)}
  end

  # Only the selected input waits, so unrelated background embeddings keep
  # using the ordinary stub. Monitoring the test prevents an abandoned barrier
  # from leaking a blocked task when an assertion fails.
  defp await_barrier(text) do
    case Application.get_env(:doctrans, :embedding_stub_barrier) do
      {^text, owner, barrier} ->
        monitor = Process.monitor(owner)
        send(owner, {:embedding_started, barrier, self()})

        receive do
          {:continue_embedding, ^barrier} ->
            Process.demonitor(monitor, [:flush])
            :ok

          {:DOWN, ^monitor, :process, ^owner, _reason} ->
            exit(:shutdown)
        end

      _ ->
        :ok
    end
  end
end
