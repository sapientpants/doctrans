defmodule Doctrans.Processing.OllamaTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.Ollama

  describe "extract_markdown/2" do
    test "returns error for non-existent file" do
      result = Ollama.extract_markdown("/nonexistent/path/image.png")

      assert {:error, reason} = result
      assert reason =~ "Failed to read image"
    end
  end

  describe "translate/3" do
    # Translation requires a running Ollama service, which is mocked in integration tests
    # Here we test the module structure and function signatures
    test "module defines expected functions" do
      # extract_markdown has a default for opts, so both arities exist
      assert function_exported?(Ollama, :extract_markdown, 2)
      # translate has a default for opts, so both arities exist
      assert function_exported?(Ollama, :translate, 3)
      assert function_exported?(Ollama, :available?, 0)
      assert function_exported?(Ollama, :list_models, 0)
    end
  end

  describe "available?/0" do
    test "returns boolean" do
      # Without Ollama running, this should return false
      result = Ollama.available?()
      assert is_boolean(result)
    end
  end

  describe "list_models/0" do
    test "returns ok tuple or error tuple" do
      result = Ollama.list_models()

      case result do
        {:ok, models} -> assert is_list(models)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end
end
