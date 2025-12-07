defmodule Doctrans.Search.EmbeddingBehaviour do
  @moduledoc """
  Behaviour for embedding generation.

  This allows mocking the embedding service in tests.
  """

  @doc """
  Generates an embedding vector for the given text.

  Returns `{:ok, embedding}` on success or `{:error, reason}` on failure.
  Returns `{:ok, nil}` for nil or empty text.
  """
  @callback generate(text :: String.t() | nil, opts :: keyword()) ::
              {:ok, Pgvector.t() | nil} | {:error, term()}
end
