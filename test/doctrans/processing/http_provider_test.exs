defmodule Doctrans.Processing.HttpProviderTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.HttpProvider

  @provider %HttpProvider.Config{
    config_key: :http_provider_test,
    circuit_key: :http_provider_test,
    name: "TestProvider"
  }

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :doctrans,
      :http_provider_test,
      base_url: "http://localhost:#{bypass.port}",
      vision_model: "test-vision",
      translation_model: "test-translate",
      chat_model: "test-chat",
      timeout: 5000
    )

    on_exit(fn ->
      Bypass.down(bypass)
      Application.delete_env(:doctrans, :http_provider_test)
    end)

    [bypass: bypass]
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "format_error/1" do
    test "handles atoms" do
      assert HttpProvider.format_error(:econnrefused) == "econnrefused"
    end

    test "handles strings" do
      assert HttpProvider.format_error("already a string") == "already a string"
    end

    test "handles other types with inspect" do
      assert HttpProvider.format_error([1, 2, 3]) == "[1, 2, 3]"
    end
  end

  describe "available?/1" do
    test "returns true when server responds 200", c do
      Bypass.expect(c.bypass, "GET", "/api/tags", fn conn ->
        json_response(conn, 200, %{models: []})
      end)

      assert HttpProvider.available?(@provider) == true
    end

    test "returns false when server returns non-200", c do
      Bypass.expect(c.bypass, "GET", "/api/tags", fn conn ->
        json_response(conn, 500, %{})
      end)

      assert HttpProvider.available?(@provider) == false
    end

    test "returns false when connection fails", c do
      Bypass.down(c.bypass)
      assert HttpProvider.available?(@provider) == false
    end
  end

  describe "list_models/1" do
    test "returns list of model names", c do
      Bypass.expect(c.bypass, "GET", "/api/tags", fn conn ->
        json_response(conn, 200, %{
          models: [
            %{"name" => "model1"},
            %{"name" => "model2"}
          ]
        })
      end)

      assert {:ok, ["model1", "model2"]} = HttpProvider.list_models(@provider)
    end

    test "returns empty list when no models", c do
      Bypass.expect(c.bypass, "GET", "/api/tags", fn conn ->
        json_response(conn, 200, %{models: []})
      end)

      assert {:ok, []} = HttpProvider.list_models(@provider)
    end

    test "returns error on non-200 status", c do
      Bypass.expect(c.bypass, "GET", "/api/tags", fn conn ->
        json_response(conn, 500, %{error: "internal error"})
      end)

      assert {:error, reason} = HttpProvider.list_models(@provider)
      assert reason =~ "500"
    end

    test "returns error on connection failure", c do
      Bypass.down(c.bypass)
      assert {:error, reason} = HttpProvider.list_models(@provider)
      assert is_binary(reason)
    end
  end

  describe "extract_markdown/3" do
    test "returns error for non-existent file" do
      result = HttpProvider.extract_markdown("/nonexistent/path/image.png", @provider)
      assert {:error, reason} = result
      assert reason =~ "Failed to read image"
    end

    test "sends correct request and parses response", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/generate"
        json_response(conn, 200, %{response: "# Extracted Text\n\nSome content"})
      end)

      assert {:ok, "# Extracted Text\n\nSome content"} =
               HttpProvider.extract_markdown(tmp_file, @provider)

      File.rm(tmp_file)
    end

    test "strips code fences from response", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        json_response(conn, 200, %{response: "```markdown\n# Title\n```"})
      end)

      assert {:ok, "# Title"} = HttpProvider.extract_markdown(tmp_file, @provider)
      File.rm(tmp_file)
    end

    test "returns error on non-200 status", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        json_response(conn, 404, %{error: "model not found"})
      end)

      assert {:error, reason} = HttpProvider.extract_markdown(tmp_file, @provider)
      assert reason =~ "404"
      File.rm(tmp_file)
    end

    test "returns error on empty response", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        json_response(conn, 200, %{response: ""})
      end)

      assert {:error, reason} = HttpProvider.extract_markdown(tmp_file, @provider)
      assert reason =~ "empty"
      File.rm(tmp_file)
    end

    test "accepts model override via opts", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        json_response(conn, 200, %{response: "result"})
      end)

      assert {:ok, "result"} =
               HttpProvider.extract_markdown(tmp_file, @provider, model: "custom-model")

      File.rm(tmp_file)
    end
  end

  describe "translate/5" do
    test "sends correct chat request", c do
      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/chat"
        json_response(conn, 200, %{message: %{content: "# Translated Text"}})
      end)

      assert {:ok, "# Translated Text"} =
               HttpProvider.translate("Original text", "en", "de", @provider)
    end

    test "strips code fences from translation", c do
      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{message: %{content: "```\n# Translated\n```"}})
      end)

      assert {:ok, "# Translated"} =
               HttpProvider.translate("Original", "en", "de", @provider)
    end

    test "returns error on non-200 status", c do
      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 400, %{error: "bad request"})
      end)

      assert {:error, reason} = HttpProvider.translate("Original", "en", "de", @provider)
      assert reason =~ "400"
    end

    test "returns error on empty response", c do
      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{message: %{content: ""}})
      end)

      assert {:error, reason} = HttpProvider.translate("Original", "en", "de", @provider)
      assert reason =~ "empty"
    end

    test "accepts model override via opts", c do
      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{message: %{content: "result"}})
      end)

      assert {:ok, "result"} =
               HttpProvider.translate("Original", "en", "de", @provider, model: "custom-model")
    end
  end

  describe "chat/3" do
    test "sends correct chat request", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        assert conn.method == "POST"
        json_response(conn, 200, %{message: %{content: "Hi there!"}})
      end)

      assert {:ok, "Hi there!"} = HttpProvider.chat(messages, @provider)
    end

    test "accepts custom num_predict", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{message: %{content: "result"}})
      end)

      assert {:ok, "result"} = HttpProvider.chat(messages, @provider, num_predict: 2048)
    end

    test "accepts model override via opts", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{message: %{content: "result"}})
      end)

      assert {:ok, "result"} = HttpProvider.chat(messages, @provider, model: "custom-model")
    end

    test "returns error on non-200 status", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 500, %{error: "server error"})
      end)

      assert {:error, reason} = HttpProvider.chat(messages, @provider)
      assert reason =~ "500"
    end

    test "returns error on unexpected response format", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{unexpected: "data"})
      end)

      assert {:error, reason} = HttpProvider.chat(messages, @provider)
      assert reason =~ "Unexpected"
    end
  end

  describe "error handling" do
    test "translate handles connection failure", c do
      Bypass.down(c.bypass)

      assert {:error, reason} = HttpProvider.translate("Original", "en", "de", @provider)
      assert is_binary(reason)
    end

    test "chat handles connection failure", c do
      Bypass.down(c.bypass)

      assert {:error, reason} =
               HttpProvider.chat([%{role: "user", content: "Hello"}], @provider)

      assert is_binary(reason)
    end
  end

  describe "empty response with length limit" do
    test "extract_markdown returns specific error for length-limited thinking", c do
      tmp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer()}.png")
      File.write!(tmp_file, "fake image data")

      Bypass.expect(c.bypass, "POST", "/api/generate", fn conn ->
        json_response(conn, 200, %{
          response: "",
          done_reason: "length",
          thinking: "thinking content"
        })
      end)

      assert {:error, reason} = HttpProvider.extract_markdown(tmp_file, @provider)
      assert reason =~ "thinking"
      File.rm(tmp_file)
    end

    test "chat returns specific error for length-limited thinking", c do
      messages = [%{role: "user", content: "Hello"}]

      Bypass.expect(c.bypass, "POST", "/api/chat", fn conn ->
        json_response(conn, 200, %{
          message: %{content: "", thinking: "thinking content"},
          done_reason: "length"
        })
      end)

      assert {:error, reason} = HttpProvider.chat(messages, @provider)
      assert reason =~ "thinking"
    end
  end
end
