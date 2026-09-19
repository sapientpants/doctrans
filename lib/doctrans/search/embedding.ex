defmodule Doctrans.Search.Embedding do
  @moduledoc """
  Generates text embeddings using an OpenAI-compatible embedding API.

  Delegates to `Doctrans.Processing.OpenAI.embed/2`, which applies the
  `:embedding_api` circuit breaker, transient retries, and the 1024-dimension
  Matryoshka truncation shared with the rest of the OpenAI client.

  Errors are locale-independent reasons, translated only by the web layer.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  alias Doctrans.Processing.OpenAI

  @doc """
  Generates an embedding vector for the given text.

  Returns `{:ok, embedding}` on success or `{:error, reason}` on failure.
  Returns `{:ok, nil}` for nil or empty text.
  """
  @impl true
  def generate(text, opts \\ [])
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}
  def generate(text, opts) when is_binary(text), do: OpenAI.embed(text, opts)
end
