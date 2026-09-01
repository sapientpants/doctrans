defmodule Doctrans.Processing.OpenAIRequestTest do
  @moduledoc """
  Exercises the real `Doctrans.Processing.OpenAI` HTTP request layer against a
  local Bypass server, covering request building, response parsing, and the
  circuit-breaker error path.
  """

  use ExUnit.Case, async: false

  alias Doctrans.Processing.OpenAI

  setup do
    prev_openai = Application.get_env(:doctrans, :openai)
    prev_embedding = Application.get_env(:doctrans, :embedding)
    test_pid = self()

    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"

    Application.put_env(
      :doctrans,
      :openai,
      base_url: url,
      api_key: "sk-test-123",
      chat_model: "test-chat-model",
      vision_model: "test-vision-model",
      translation_model: "test-translation-model"
    )

    Application.put_env(
      :doctrans,
      :embedding,
      base_url: url,
      api_key: "sk-embed-456",
      model: "test-embed-model"
    )

    on_exit(fn ->
      restore_env(:openai, prev_openai)
      restore_env(:embedding, prev_embedding)
      Bypass.down(bypass)
    end)

    %{bypass: bypass, url: url, test_pid: test_pid}
  end

  defp restore_env(key, value) do
    if value,
      do: Application.put_env(:doctrans, key, value),
      else: Application.delete_env(:doctrans, key)
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  # Reads the request headers and body from a raw socket so the test server
  # can answer. Keeps the socket sane before the response is written.
  defp drain_request(sock) do
    {headers, leftover} = read_headers(sock, "")
    length = content_length(headers)
    read_body(sock, length - byte_size(leftover), leftover)
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} ->
        acc = acc <> data

        case :binary.match(acc, "\r\n\r\n") do
          {offset, 4} ->
            headers = binary_part(acc, 0, offset)
            leftover = binary_part(acc, offset + 4, byte_size(acc) - offset - 4)
            {headers, leftover}

          :nomatch ->
            read_headers(sock, acc)
        end

      {:error, reason} ->
        raise "request header read failed: #{inspect(reason)}"
    end
  end

  defp content_length(headers) do
    case :binary.match(headers, "content-length: ") do
      {start, _len} ->
        line = binary_part(headers, start + 16, byte_size(headers) - start - 16)
        [value | _] = String.split(line)
        String.to_integer(value)

      :nomatch ->
        0
    end
  end

  defp read_body(_sock, remaining, acc) when remaining <= 0, do: acc

  defp read_body(sock, remaining, acc) do
    case :gen_tcp.recv(sock, remaining, 10_000) do
      {:ok, data} -> read_body(sock, remaining - byte_size(data), acc <> data)
      {:error, reason} -> raise "request body read failed: #{inspect(reason)}"
    end
  end

  describe "chat/2" do
    test "sends request with configured model and returns content", %{
      bypass: bypass,
      test_pid: test_pid
    } do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:chat_request, conn.req_headers, body})

        json(conn, 200, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "  Hello from model  "}}
          ]
        })
      end)

      assert {:ok, "Hello from model"} = OpenAI.chat([%{role: "user", content: "Hi"}])

      assert_receive {:chat_request, headers, body}
      assert {"authorization", "Bearer sk-test-123"} in headers
      request = Jason.decode!(body)
      assert request["model"] == "test-chat-model"
      assert request["messages"] == [%{"role" => "user", "content" => "Hi"}]
      assert request["max_tokens"] == 4096
      refute Map.has_key?(request, "enable_thinking")
    end

    test "sends enable_thinking=false when think: false", %{
      bypass: bypass,
      test_pid: test_pid
    } do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:chat_body, body})
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      assert {:ok, "ok"} =
               OpenAI.chat([%{role: "user", content: "x"}], think: false, model: "custom")

      assert_receive {:chat_body, body}
      request = Jason.decode!(body)
      assert request["model"] == "custom"
      assert request["enable_thinking"] == false
    end

    test "returns error when content is empty", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "  "}}]})
      end)

      assert {:error, "Model returned empty response"} =
               OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns error when message has no content key", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"choices" => [%{"message" => %{"role" => "assistant"}}]})
      end)

      assert {:error, "Empty or missing response from API"} =
               OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns error for empty message map", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"choices" => [%{"message" => %{}}]})
      end)

      assert {:error, "Empty or missing response from API"} =
               OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns reasoning content when content is missing", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(
          conn,
          200,
          %{"choices" => [%{"message" => %{"reasoning_content" => "Thought it through"}}]}
        )
      end)

      assert {:ok, "Thought it through"} = OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns reasoning content when content is blank", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(
          conn,
          200,
          %{"choices" => [%{"message" => %{"content" => "", "reasoning" => "hmm"}}]}
        )
      end)

      assert {:ok, "hmm"} = OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "uses first choice when multiple are returned", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{
          "choices" => [
            %{"message" => %{"content" => "first"}},
            %{"message" => %{"content" => "second"}}
          ]
        })
      end)

      assert {:ok, "first"} = OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns content when truncated at length", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{
          "choices" => [
            %{"finish_reason" => "length", "message" => %{"content" => "partial"}}
          ]
        })
      end)

      assert {:ok, "partial"} = OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns error for invalid response format", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"unexpected" => true})
      end)

      assert {:error, "Invalid response format from API"} =
               OpenAI.chat([%{role: "user", content: "x"}])
    end

    test "returns error and melts fuse on non-200 status", %{bypass: bypass} do
      # stub (not expect): :transient retries POSTs on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 500, %{"error" => %{"message" => "boom"}})
      end)

      assert {:error, reason} = OpenAI.chat([%{role: "user", content: "x"}])
      assert reason =~ "API call failed"
    end

    test "returns error on transport failure" do
      Application.put_env(
        :doctrans,
        :openai,
        base_url: "http://127.0.0.1:1",
        api_key: nil,
        chat_model: "test-chat-model"
      )

      assert {:error, reason} = OpenAI.chat([%{role: "user", content: "x"}])
      assert reason =~ "API call failed"
    end

    test "omits authorization header when api key is nil", %{
      bypass: bypass,
      url: url,
      test_pid: test_pid
    } do
      Application.put_env(:doctrans, :openai,
        base_url: url,
        api_key: nil,
        chat_model: "test-chat-model"
      )

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, {:chat_headers, conn.req_headers})
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      assert {:ok, "ok"} = OpenAI.chat([%{role: "user", content: "x"}])

      assert_receive {:chat_headers, headers}
      refute Enum.any?(headers, fn {name, _} -> name == "authorization" end)
    end
  end

  describe "extract_markdown/2" do
    test "sends multimodal request and returns cleaned markdown", %{
      bypass: bypass,
      test_pid: test_pid
    } do
      path = write_tmp_image(".png")

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:extract_body, body})

        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "```markdown\n# Title\n"}}]})
      end)

      assert {:ok, "# Title"} = OpenAI.extract_markdown(path)

      assert_receive {:extract_body, body}
      request = Jason.decode!(body)
      assert request["model"] == "test-vision-model"
      content = Enum.at(request["messages"], 0)["content"]
      assert [%{"type" => "text"}, %{"type" => "image_url"}] = content
      image = Enum.find(content, fn part -> part["type"] == "image_url" end)
      assert image["image_url"]["url"] =~ "data:image/png;base64,"
    end

    test "maps .jpg extension to jpeg mime type", %{bypass: bypass, test_pid: test_pid} do
      path = write_tmp_image(".jpg")

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:extract_body, body})
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "content"}}]})
      end)

      assert {:ok, "content"} = OpenAI.extract_markdown(path)

      assert_receive {:extract_body, body}
      request = Jason.decode!(body)
      assert request["model"] == "test-vision-model"

      content = Enum.at(request["messages"], 0)["content"]
      image = Enum.find(content, fn part -> part["type"] == "image_url" end)
      assert image["image_url"]["url"] =~ "data:image/jpeg;base64,"
    end

    test "returns error when extraction is empty", %{bypass: bypass} do
      path = write_tmp_image(".png")

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "   "}}]})
      end)

      assert {:error, "Model returned empty response for image"} = OpenAI.extract_markdown(path)
    end

    test "returns error on non-200 status", %{bypass: bypass} do
      path = write_tmp_image(".png")

      # stub (not expect): :transient retries POSTs on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 503, %{"error" => "unavailable"})
      end)

      assert {:error, reason} = OpenAI.extract_markdown(path)
      assert reason =~ "API call failed"
    end
  end

  defp write_tmp_image(ext) do
    path =
      Path.join(
        System.tmp_dir!(),
        "openai_test_image_#{System.unique_integer([:positive])}#{ext}"
      )

    File.write!(path, "fake-image-data")
    path
  end

  describe "translate/4" do
    test "translates via chat and cleans response", %{bypass: bypass, test_pid: test_pid} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:translate_body, body})

        json(conn, 200, %{
          "choices" => [
            %{"message" => %{"content" => "\nTranslated text\n"}}
          ]
        })
      end)

      assert {:ok, "Translated text"} = OpenAI.translate("Original text", "de", "en")

      assert_receive {:translate_body, body}
      request = Jason.decode!(body)
      assert request["model"] == "test-translation-model"
      assert request["max_tokens"] == 8192
      assert request["enable_thinking"] == false
    end

    test "honours explicit model override in translation", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 200, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      assert {:ok, "ok"} =
               OpenAI.translate("text", "de", "en", model: "my-translation-model")
    end

    test "propagates errors", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 400, %{"error" => "bad request"})
      end)

      assert {:error, reason} = OpenAI.translate("Original text", "de", "en")
      assert reason =~ "API call failed"
    end
  end

  describe "chat_stream/3" do
    test "collects SSE deltas into final content", %{bypass: bypass, test_pid: test_pid} do
      sse =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"role" => "assistant", "content" => "Hel"}}]
          }) <>
          "\n\ndata: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "lo"}}]}) <>
          "\n\ndata: [DONE]\n\n"

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:stream_request, body})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse)
      end)

      on_delta = fn piece -> send(test_pid, {:delta, piece}) end

      assert {:ok, "Hello"} =
               OpenAI.chat_stream([%{role: "user", content: "hi"}], on_delta)

      assert_receive {:delta, "Hel"}
      assert_receive {:delta, "lo"}

      assert_receive {:stream_request, body}
      request = Jason.decode!(body)
      assert request["stream"] == true
    end

    test "invokes on_delta as SSE data arrives in fragments", %{test_pid: test_pid} do
      payload =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{"role" => "assistant", "content" => "hél"}}]
        })

      # Split the JSON frame mid-line, inside the multibyte "é", so the
      # collector's line buffer must reassemble across TCP segments
      {offset, 2} = :binary.match(payload, "é")
      mid = offset + 1

      frag1 = "data: " <> binary_part(payload, 0, mid)
      frag2 = binary_part(payload, mid, byte_size(payload) - mid) <> "\n\n"

      frag3 =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "lo"}}]}) <>
          "\n\ndata: [DONE]\n\n"

      body = frag1 <> frag2 <> frag3

      parent = self()

      server =
        spawn(fn ->
          {:ok, lsock} =
            :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, nodelay: true])

          {:ok, port} = :inet.port(lsock)
          send(parent, {:sse_port, port})

          {:ok, sock} = :gen_tcp.accept(lsock)
          drain_request(sock)

          headers =
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
              "content-length: #{byte_size(body)}\r\n\r\n"

          # nodelay is set on the socket, so each fragment is flushed as its
          # own segment and the collector must reassemble the lines
          :gen_tcp.send(sock, headers)
          :gen_tcp.send(sock, frag1)
          Process.sleep(50)
          :gen_tcp.send(sock, frag2)
          Process.sleep(50)
          :gen_tcp.send(sock, frag3)
          :gen_tcp.close(sock)
        end)

      on_exit(fn -> :erlang.exit(server, :kill) end)

      port =
        receive do
          {:sse_port, port} -> port
        after
          5_000 -> flunk("SSE test server did not start")
        end

      Application.put_env(
        :doctrans,
        :openai,
        base_url: "http://127.0.0.1:#{port}",
        api_key: nil,
        chat_model: "test-chat-model"
      )

      on_delta = fn piece -> send(test_pid, {:delta, piece}) end

      assert {:ok, "héllo"} =
               OpenAI.chat_stream([%{role: "user", content: "hi"}], on_delta)

      assert_receive {:delta, "hél"}
      assert_receive {:delta, "lo"}
    end

    test "returns error for non-200 status", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        json(conn, 404, %{"error" => "nope"})
      end)

      assert {:error, reason} =
               OpenAI.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end)

      assert reason =~ "API call failed"
    end

    test "returns error on transport failure" do
      Application.put_env(
        :doctrans,
        :openai,
        base_url: "http://127.0.0.1:1",
        api_key: nil,
        chat_model: "test-chat-model"
      )

      assert {:error, reason} =
               OpenAI.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end)

      assert reason =~ "API call failed"
    end
  end

  describe "embed/2" do
    test "returns truncated embedding vector", %{bypass: bypass, test_pid: test_pid} do
      vector = Enum.map(1..1500, fn _ -> 0.5 end)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:embed_request, conn.req_headers, body})
        json(conn, 200, %{"data" => [%{"embedding" => vector}]})
      end)

      assert {:ok, result} = OpenAI.embed("some text")
      assert length(Pgvector.to_list(result)) == 1024

      assert_receive {:embed_request, headers, body}
      assert {"authorization", "Bearer sk-embed-456"} in headers
      request = Jason.decode!(body)
      assert request["model"] == "test-embed-model"
      assert request["input"] == "some text"
    end

    test "prefers model from opts over config", %{bypass: bypass, test_pid: test_pid} do
      vector = List.duplicate(0.1, 1024)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:embed_request, body})
        json(conn, 200, %{"data" => [%{"embedding" => vector}]})
      end)

      assert {:ok, result} = OpenAI.embed("text", model: "custom-embed")
      assert length(Pgvector.to_list(result)) == 1024

      assert_receive {:embed_request, body}
      assert Jason.decode!(body)["model"] == "custom-embed"
    end

    test "returns error when the vector is too short", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]})
      end)

      assert {:error, reason} = OpenAI.embed("text")
      assert reason =~ "too short"
    end

    test "returns error on non-200 status", %{bypass: bypass} do
      # stub (not expect): :transient retries POSTs on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, reason} = OpenAI.embed("text")
      assert reason =~ "API call failed"
    end

    test "returns error for invalid body", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"unexpected" => true})
      end)

      assert {:error, "Invalid embedding response from API"} = OpenAI.embed("text")
    end
  end

  describe "list_models/0" do
    test "returns model names", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        json(conn, 200, %{"data" => [%{"id" => "model-a"}, %{"id" => "model-b"}]})
      end)

      assert {:ok, ["model-a", "model-b"]} = OpenAI.list_models()
    end

    test "returns error on non-200 status", %{bypass: bypass} do
      # stub (not expect): safe GETs are retried on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, reason} = OpenAI.list_models()
      assert reason =~ "API call failed"
    end

    test "returns error for invalid body", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        json(conn, 200, %{"data" => "not-a-list"})
      end)

      assert {:error, "Invalid response format from API"} = OpenAI.list_models()
    end
  end

  describe "available?/0" do
    test "returns true when models endpoint is up", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        json(conn, 200, %{"data" => []})
      end)

      assert OpenAI.available?()
    end

    test "returns false when models endpoint fails", %{bypass: bypass} do
      # stub (not expect): safe GETs are retried on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      refute OpenAI.available?()
    end
  end
end
