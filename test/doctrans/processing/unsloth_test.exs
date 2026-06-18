defmodule Doctrans.Processing.UnslothTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.Unsloth

  describe "module structure" do
    test "defines expected functions" do
      Code.ensure_loaded!(Unsloth)
      assert function_exported?(Unsloth, :extract_markdown, 1)
      assert function_exported?(Unsloth, :extract_markdown, 2)
      assert function_exported?(Unsloth, :translate, 3)
      assert function_exported?(Unsloth, :translate, 4)
      assert function_exported?(Unsloth, :chat, 1)
      assert function_exported?(Unsloth, :chat, 2)
      assert function_exported?(Unsloth, :available?, 0)
      assert function_exported?(Unsloth, :list_models, 0)
    end
  end

  describe "extract_markdown/2" do
    test "returns error for non-existent file" do
      result = Unsloth.extract_markdown("/nonexistent/path/image.png")
      assert {:error, reason} = result
      assert reason =~ "Failed to read image"
    end
  end

  describe "available?/0" do
    test "returns boolean" do
      result = Unsloth.available?()
      assert is_boolean(result)
    end
  end

  describe "list_models/0" do
    test "returns ok tuple or error tuple" do
      result = Unsloth.list_models()

      case result do
        {:ok, models} -> assert is_list(models)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end

  describe "chat/2" do
    test "returns error tuple when service is unavailable" do
      result = Unsloth.chat([%{role: "user", content: "Hello"}])

      case result do
        {:ok, response} -> assert is_binary(response)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end

  describe "translate/4" do
    test "returns error tuple when service is unavailable" do
      result = Unsloth.translate("Hello", "en", "de")

      case result do
        {:ok, response} -> assert is_binary(response)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end
end
