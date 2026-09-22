defmodule Doctrans.Search.EmbeddingOptsStub do
  @moduledoc """
  Embedding client that reports the options it was handed, then succeeds.

  Every other embedding stub here ignores `opts`, which makes the *bounds* on a
  call invisible to tests. They matter: a readiness probe that inherits the
  60-second indexing default instead of passing its own timeout still passes
  every assertion about its result, and only misbehaves in front of a user
  waiting on a modal. Reporting `{:embedding_opts, text, opts}` to
  `:embedding_opts_observer` makes that difference assertable.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  alias Doctrans.Search.EmbeddingStub

  @impl true
  def generate(text, opts \\ []) do
    case Application.get_env(:doctrans, :embedding_opts_observer) do
      pid when is_pid(pid) -> send(pid, {:embedding_opts, text, opts})
      _absent -> :ok
    end

    EmbeddingStub.generate(text, opts)
  end
end
