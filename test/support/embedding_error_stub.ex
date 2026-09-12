defmodule Doctrans.Search.EmbeddingErrorStub do
  @moduledoc """
  Embedding client that always fails with a configured reason.

  Set `:embedding_error_reason` to choose between a transient and a permanent
  failure; it defaults to a transient one.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  @impl true
  def generate(_text, _opts) do
    {:error, Application.get_env(:doctrans, :embedding_error_reason, :timeout)}
  end
end
