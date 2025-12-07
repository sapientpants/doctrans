defmodule Doctrans.Search.EmbeddingWorkerTest do
  use ExUnit.Case, async: true

  alias Doctrans.Search.EmbeddingWorker

  describe "EmbeddingWorker GenServer" do
    test "starts successfully" do
      # The worker is already started by the application
      assert Process.whereis(EmbeddingWorker) != nil
    end

    test "generate_embedding/1 accepts page id" do
      # Just verify the function doesn't crash with a fake ID
      # The actual embedding work happens asynchronously
      fake_id = Ecto.UUID.generate()

      # This should not raise - it just casts to the GenServer
      assert :ok = EmbeddingWorker.generate_embedding(fake_id)
    end

    test "module exports expected functions" do
      assert function_exported?(EmbeddingWorker, :start_link, 1)
      assert function_exported?(EmbeddingWorker, :generate_embedding, 1)
    end
  end
end
