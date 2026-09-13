defmodule Doctrans.Search.EmbeddingNilStub do
  @moduledoc """
  Embedding client that succeeds with no vector.

  `{:ok, nil}` is a legal `Doctrans.Search.EmbeddingBehaviour` result, and it is
  the one success that cannot be ranked against: a NULL vector searches nothing.
  Retrieval has to treat it as a degraded mode rather than as a ranking that
  ran, which is what this stub exists to pin.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  @impl true
  def generate(_text, _opts \\ []), do: {:ok, nil}
end
