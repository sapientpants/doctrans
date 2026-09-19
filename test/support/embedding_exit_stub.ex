defmodule Doctrans.Search.EmbeddingExitStub do
  @moduledoc """
  Embedding client that exits, so a test can drive the task-exit path.

  The exit reason carries the text it was called with, standing in for the
  stacktrace a real crash carries -- an embedding call's frames hold the query
  and its 1024-float vector. That is what lets a test prove the *returned*
  reason keeps none of it.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  # Never returning is the whole point, so the behaviour's success typing cannot
  # be met and dialyzer is right that it never will be.
  @dialyzer {:nowarn_function, [generate: 1, generate: 2]}

  @impl true
  def generate(text, _opts \\ []) do
    exit({:embedding_crashed, text, List.duplicate(0.1, 1024)})
  end
end
