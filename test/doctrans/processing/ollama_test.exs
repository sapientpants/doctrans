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

  describe "strip_code_fences/1" do
    test "strips markdown code fences" do
      input = "```markdown\n# Hello\nWorld\n```"
      assert Ollama.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips code fences with md language" do
      input = "```md\n# Hello\nWorld\n```"
      assert Ollama.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips plain code fences without language" do
      input = "```\n# Hello\nWorld\n```"
      assert Ollama.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips code fences with other language specifiers" do
      input = "```elixir\ndefmodule Foo do\nend\n```"
      assert Ollama.strip_code_fences(input) == "defmodule Foo do\nend"
    end

    test "handles closing fence without preceding newline" do
      input = "```\nHello World```"
      assert Ollama.strip_code_fences(input) == "Hello World"
    end

    test "handles closing fence with trailing whitespace" do
      input = "```\nHello\n```  "
      assert Ollama.strip_code_fences(input) == "Hello"
    end

    test "returns text unchanged when no code fences present" do
      input = "# Hello\nWorld"
      assert Ollama.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "trims whitespace from result" do
      input = "```\n  Hello  \n```"
      assert Ollama.strip_code_fences(input) == "Hello"
    end
  end
end
