defmodule Doctrans.Search.EmbeddingRequestTest do
  @moduledoc """
  Exercises the real `Doctrans.Search.Embedding` HTTP request layer against a
  local Bypass server, covering request building, response parsing, the
  Matryoshka truncation and the `:embedding_api` circuit-breaker path.

  `async: false`: the `:embedding` settings and Req's default options are
  VM-global, and the `:embedding_api` fuse is shared.
  """

  use Doctrans.EnvCase, async: false

  alias Doctrans.Resilience.{CircuitBreaker, FuseProbe}
  alias Doctrans.Search.Embedding
  alias Doctrans.TestEnv

  setup do
    CircuitBreaker.reset(:embedding_api)
    prev_req = Application.fetch_env(:req, :default_options)
    # Exercise the real retry path without spending seconds on backoff in tests
    # whose assertions concern the resulting HTTP contract.
    Req.default_options(Keyword.put(Req.default_options(), :retry_delay, 0))
    test_pid = self()

    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"

    # The shared endpoint the embedding section falls back to.
    TestEnv.put_env(:openai,
      base_url: url,
      api_key: "sk-test-123",
      chat_model: "test-chat-model"
    )

    TestEnv.put_env(:embedding,
      base_url: url,
      api_key: "sk-embed-456",
      model: "test-embed-model"
    )

    on_exit(fn ->
      CircuitBreaker.reset(:embedding_api)

      case prev_req do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end

      Bypass.down(bypass)
    end)

    %{bypass: bypass, url: url, test_pid: test_pid}
  end

  describe "generate/2" do
    test "uses the shared endpoint without inserting a double slash", %{bypass: bypass} do
      TestEnv.put_env(:embedding, base_url: nil, model: "embed")

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"data" => [%{"embedding" => List.duplicate(0.1, 1024)}]})
      end)

      assert {:ok, _embedding} = Embedding.generate("text")
    end

    test "returns truncated embedding vector", %{bypass: bypass, test_pid: test_pid} do
      vector = Enum.map(1..1500, &(&1 / 2))

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:embed_request, conn.req_headers, body})
        json(conn, 200, %{"data" => [%{"embedding" => vector}]})
      end)

      assert {:ok, result} = Embedding.generate("some text")
      assert Pgvector.to_list(result) == Enum.map(1..1024, &(&1 / 2))

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

      assert {:ok, result} = Embedding.generate("text", model: "custom-embed")
      assert length(Pgvector.to_list(result)) == 1024

      assert_receive {:embed_request, body}
      assert Jason.decode!(body)["model"] == "custom-embed"
    end

    test "returns error when the vector is too short", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]})
      end)

      assert {:error, reason} = Embedding.generate("text")
      assert {:embedding_too_short, [expected: 1024, actual: 3]} = reason
    end

    test "returns error on non-200 status", %{bypass: bypass} do
      # stub (not expect): :transient retries POSTs on 5xx, so the route may hit multiple times
      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:http_error, [status: 500]}} = Embedding.generate("text")
    end

    test "returns error for invalid body", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"unexpected" => true})
      end)

      assert {:error, :invalid_embedding_response} = Embedding.generate("text")
    end

    test "reports a malformed 200 without counting it against the fuse", %{bypass: bypass} do
      FuseProbe.watch_failures()

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 200, %{"unexpected" => true})
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_embedding_response} = Embedding.generate("text")
        end)

      assert log =~ "API call failed"
      refute_received {:circuit_failure, :embedding_api}
    end

    # The ask used to live in `Search.Indexer` alone, so search and chat
    # retrieval, which call this directly, kept sending requests -- and melting
    # the fuse further -- after it had blown. Every caller is held off now.
    test "rejects the call without reaching the API when :embedding_api is blown", %{
      bypass: bypass,
      test_pid: test_pid
    } do
      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        send(test_pid, :http_request)
        json(conn, 200, %{"data" => [%{"embedding" => List.duplicate(0.1, 1024)}]})
      end)

      FuseProbe.blow(:embedding_api)

      assert {:error, :circuit_open} = Embedding.generate("text")
      refute_received :http_request
    end

    test "a server that keeps failing blows :embedding_api and is then left alone", %{
      bypass: bypass,
      test_pid: test_pid
    } do
      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        send(test_pid, :http_request)
        json(conn, 500, %{"error" => "boom"})
      end)

      for _ <- 1..4, do: assert({:error, _} = Embedding.generate("text"))
      assert CircuitBreaker.status(:embedding_api) == :blown

      flush_requests()
      assert {:error, :circuit_open} = Embedding.generate("text")
      refute_received :http_request
    end

    test "keeps an echoed request body out of the error log", %{bypass: bypass} do
      # A 4xx from an OpenAI-compatible server commonly quotes the input it
      # rejected. For an embedding call that input is the user's search text, so
      # it must not reach the log level production actually runs at.
      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        json(conn, 400, %{"error" => %{"message" => "invalid input: my-secret-query"}})
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:error, _reason} = Embedding.generate("my-secret-query")
        end)

      refute log =~ "my-secret-query"
      assert log =~ "API call failed"
    end
  end

  describe "the endpoint URL in the debug log" do
    # The URL is logged before Req ever sees it, so Req's own header redaction
    # does not cover it, and dev runs at :debug.
    setup do
      # The suite runs Logger at :warning, which drops the line before any
      # capture handler sees it; dev runs at :debug, which is the case at issue.
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      :ok
    end

    # Both forms matter, and only the second one ever failed: with a parseable
    # host, stripping `URI.userinfo` worked. A scheme-less endpoint -- the
    # realistic operator typo, since the base URL is a raw env var -- leaves the
    # credentials in the authority, where the old redaction never touched them.
    for {shape, scheme} <- [{"a parseable", "http://"}, {"a scheme-less", ""}] do
      test "the request line carries no credentials from #{shape} endpoint", %{
        bypass: bypass
      } do
        TestEnv.put_env(:embedding,
          base_url: "#{unquote(scheme)}user:s3cret@localhost:#{bypass.port}",
          model: "test-embedding-model"
        )

        Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
          json(conn, 200, %{"data" => [%{"embedding" => List.duplicate(0.1, 1024)}]})
        end)

        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            attempt(fn -> Embedding.generate("text") end)
          end)

        assert log =~ "Embedding POST"
        refute log =~ "s3cret"
      end
    end

    # A scheme-less base URL cannot be requested at all; the log line under test
    # is written before that failure, so whatever the call does with it is moot.
    defp attempt(fun) do
      fun.()
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  # Drains the request notifications already in the mailbox so a `refute_received`
  # that follows speaks to the next call alone.
  defp flush_requests do
    receive do
      :http_request -> flush_requests()
    after
      0 -> :ok
    end
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end
end
