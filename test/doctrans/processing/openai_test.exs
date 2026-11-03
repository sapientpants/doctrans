defmodule Doctrans.Processing.OpenAITest do
  @moduledoc """
  Covers `Doctrans.Processing.OpenAI`'s local helpers: the file check in front
  of an extraction and the code-fence stripping every stage's output goes
  through. Neither touches the network or any global setting, so the file runs
  concurrently with the rest of the suite.

  The HTTP surface -- chat, streaming, extraction, translation, the model list
  and the circuit-breaker paths -- is covered against a local Bypass server in
  `Doctrans.Processing.OpenAIRequestTest`.
  """

  use Doctrans.EnvCase, async: true

  alias Doctrans.Processing.OpenAI

  # A rejected request is logged at :error by `ApiFailure`.
  @moduletag :capture_log

  describe "extract_markdown/2" do
    test "returns error for non-existent file" do
      result = OpenAI.extract_markdown("/nonexistent/path/image.png")

      assert {:error, reason} = result
      assert {:image_unreadable, [reason: :enoent]} = reason
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
