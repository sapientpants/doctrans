defmodule Doctrans.Search.EmbeddingDimensionStub do
  @moduledoc """
  Embedding client that succeeds with a vector of the wrong width.

  The search statement compares the query vector against stored 1024-dimension
  embeddings, so a narrower one makes Postgres reject the comparison. That is
  how a test reaches the statement's failure branch without stubbing out the
  statement it is meant to be checking: the embedding call succeeds, and the
  real query fails for a real reason.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  @impl true
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}
  def generate(_text, _opts), do: {:ok, Pgvector.new([0.1, 0.2, 0.3])}
end
