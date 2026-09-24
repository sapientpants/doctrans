defmodule Doctrans.Search.EmbeddingTest do
  use Doctrans.EnvCase, async: false

  alias Doctrans.Search.Embedding
  alias Doctrans.TestEnv

  setup do
    bypass = Bypass.open()

    TestEnv.put_env(:embedding,
      base_url: "http://localhost:#{bypass.port}",
      model: "configured-embedding-model",
      api_key: nil
    )

    %{bypass: bypass}
  end

  test "nil and empty inputs return no vector without requesting an embedding", %{bypass: bypass} do
    owner = self()

    Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
      send(owner, :unexpected_embedding_request)
      json(conn, 400, %{"error" => "empty input"})
    end)

    for text <- [nil, ""] do
      assert Embedding.generate(text) == {:ok, nil}
      assert Embedding.generate(text, model: "unused") == {:ok, nil}
    end

    refute_received :unexpected_embedding_request
  end

  test "returns the server's vector for the supplied text and configured model", %{bypass: bypass} do
    values = Enum.map(1..1024, &(&1 / 1024))

    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "input" => "source passage",
               "model" => "configured-embedding-model"
             }

      json(conn, 200, %{"data" => [%{"embedding" => values}]})
    end)

    assert {:ok, vector} = Embedding.generate("source passage")
    assert Pgvector.to_list(vector) == values
  end

  test "forwards an explicit model override", %{bypass: bypass} do
    values = List.duplicate(0.25, 1024)

    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"input" => "custom passage", "model" => "custom-model"}
      json(conn, 200, %{"data" => [%{"embedding" => values}]})
    end)

    assert {:ok, vector} = Embedding.generate("custom passage", model: "custom-model")
    assert Pgvector.to_list(vector) == values
  end

  @tag :capture_log
  test "preserves the API's permanent failure", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      json(conn, 401, %{"error" => "unauthorized"})
    end)

    assert Embedding.generate("rejected passage") == {:error, {:http_error, [status: 401]}}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
