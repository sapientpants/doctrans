defmodule Doctrans.Processing.OpenAITest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.OpenAI

  describe "extract_markdown/2" do
    test "returns error for non-existent file" do
      result = OpenAI.extract_markdown("/nonexistent/path/image.png")

      assert {:error, reason} = result
      assert reason =~ "Could not read image"
    end
  end

  describe "translate/4" do
    # Translation requires a running API server, which is mocked in integration tests.
    # Here we test the module structure and function signatures
    test "module defines expected functions" do
      Code.ensure_loaded!(OpenAI)
      # extract_markdown has a default for opts, so it can be called with 1 arg
      assert function_exported?(OpenAI, :extract_markdown, 1)
      # translate has a default for opts, so it can be called with 3 or 4 args
      assert function_exported?(OpenAI, :translate, 3)
      assert function_exported?(OpenAI, :translate, 4)
      assert function_exported?(OpenAI, :available?, 0)
      assert function_exported?(OpenAI, :list_models, 0)
    end
  end

  describe "available?/0" do
    test "returns boolean" do
      # Without an API server running, this should return false
      result = OpenAI.available?()
      assert is_boolean(result)
    end
  end

  describe "list_models/0" do
    test "returns ok tuple or error tuple" do
      result = OpenAI.list_models()

      case result do
        {:ok, models} -> assert is_list(models)
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end

  describe "strip_code_fences/1" do
    test "strips markdown code fences" do
      input = "```markdown\n# Hello\nWorld\n```"
      assert OpenAI.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips code fences with md language" do
      input = "```md\n# Hello\nWorld\n```"
      assert OpenAI.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips plain code fences without language" do
      input = "```\n# Hello\nWorld\n```"
      assert OpenAI.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "strips code fences with other language specifiers" do
      input = "```elixir\ndefmodule Foo do\nend\n```"
      assert OpenAI.strip_code_fences(input) == "defmodule Foo do\nend"
    end

    test "handles closing fence without preceding newline" do
      input = "```\nHello World```"
      assert OpenAI.strip_code_fences(input) == "Hello World"
    end

    test "handles closing fence with trailing whitespace" do
      input = "```\nHello\n```  "
      assert OpenAI.strip_code_fences(input) == "Hello"
    end

    test "returns text unchanged when no code fences present" do
      input = "# Hello\nWorld"
      assert OpenAI.strip_code_fences(input) == "# Hello\nWorld"
    end

    test "trims whitespace from result" do
      input = "```\n  Hello  \n```"
      assert OpenAI.strip_code_fences(input) == "Hello"
    end
  end
end
