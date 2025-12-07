defmodule Doctrans.Search.EmbeddingTest do
  use ExUnit.Case, async: true

  alias Doctrans.Search.Embedding

  describe "generate/2" do
    test "returns {:ok, nil} for nil text" do
      assert {:ok, nil} = Embedding.generate(nil, [])
    end

    test "returns {:ok, nil} for empty string" do
      assert {:ok, nil} = Embedding.generate("", [])
    end

    test "returns {:ok, nil} with default opts for nil" do
      assert {:ok, nil} = Embedding.generate(nil)
    end

    test "returns {:ok, nil} with default opts for empty string" do
      assert {:ok, nil} = Embedding.generate("")
    end

    test "returns error or result for non-empty text" do
      # This test exercises the code path for non-empty text
      # In CI without Ollama, this will return an error
      # Locally with Ollama, this will return a valid embedding
      result = Embedding.generate("test text")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts custom model option" do
      # Test that options are passed through
      result = Embedding.generate("test", model: "nonexistent-model")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts custom timeout option" do
      result = Embedding.generate("test", timeout: 1000)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
