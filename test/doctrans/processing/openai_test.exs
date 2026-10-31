defmodule Doctrans.Processing.OpenAITest do
  @moduledoc """
  Covers `Doctrans.Processing.OpenAI`'s local helpers and its model-list probe.

  `list_models/0` is the call the reprocess modal makes before anything has
  been processed, and it used to be asserted here with `is_list/1` against
  whatever happened to be listening on the configured host — an assertion that
  cannot fail, run against the network. It now talks to a local Bypass server
  and is asserted exactly, reachable and not. Nothing in this file leaves the
  machine.

  The unreachable case is driven through a base URL Req cannot build a request
  from rather than a closed port: Req retries a safe GET on `:econnrefused`, so
  a refused connection costs about seven seconds of backoff per call, and the
  probe takes no options this test could pass `retry: false` through, so it
  reports a rejected request instead.

  The full HTTP surface — chat, streaming, extraction, translation, embedding
  and the circuit-breaker paths — is covered in
  `Doctrans.Processing.OpenAIRequestTest`.
  """

  use Doctrans.EnvCase, async: false

  alias Doctrans.Processing.OpenAI
  alias Doctrans.TestEnv

  # A rejected request is logged at :error by `ApiFailure`.
  @moduletag :capture_log

  describe "extract_markdown/2" do
    test "returns error for non-existent file" do
      result = OpenAI.extract_markdown("/nonexistent/path/image.png")

      assert {:error, reason} = result
      assert {:image_unreadable, [reason: :enoent]} = reason
    end
  end

  describe "list_models/0" do
    setup :bypass_api

    test "reports the status when the API rejects the request", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 401, "unauthorized")
      end)

      assert OpenAI.list_models() == {:error, {:http_error, [status: 401]}}
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

  defp bypass_api(_context) do
    bypass = Bypass.open()
    put_openai_env(base_url: "http://localhost:#{bypass.port}", api_key: "sk-test-123")
    %{bypass: bypass}
  end

  # Merged, not replaced: `:openai` also carries the vision, translation and chat
  # model names, and application env is global, so replacing the list would unset
  # them for every process for as long as this test runs.
  defp put_openai_env(overrides) do
    merged = Keyword.merge(Application.fetch_env!(:doctrans, :openai), overrides)
    TestEnv.put_env(:openai, merged)
  end
end
