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
  end
end
