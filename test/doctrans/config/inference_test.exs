defmodule Doctrans.Config.InferenceTest do
  use ExUnit.Case, async: false

  alias Doctrans.Config.Inference

  setup do
    previous = Map.new([:openai, :embedding], &{&1, Application.fetch_env!(:doctrans, &1)})

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:doctrans, key, value)
    end)

    :ok
  end

  defp configure(chat_url, embedding_url) do
    Application.put_env(:doctrans, :openai, base_url: chat_url, chat_model: "chat")
    Application.put_env(:doctrans, :embedding, base_url: embedding_url)
  end

  test "the shipped default configuration is local" do
    assert Inference.local?()
    assert Inference.remote_hosts() == []
    assert Inference.destination_label() == ""

    assert Inference.endpoints() == [
             %{
               path: :chat,
               host: "localhost",
               base_url: "http://localhost:8000",
               locality: :local
             },
             %{
               path: :embedding,
               host: "localhost",
               base_url: "http://localhost:8000",
               locality: :local
             }
           ]
  end

  test "a remote chat endpoint drops the local claim and names the host" do
    configure("https://api.somewhere.com/v1", nil)

    refute Inference.local?()
    assert Inference.remote_hosts() == ["api.somewhere.com"]
    assert Inference.destination_label() == "api.somewhere.com"

    assert Inference.endpoints() == [
             %{
               path: :chat,
               host: "api.somewhere.com",
               base_url: "https://api.somewhere.com/v1",
               locality: :remote
             },
             %{
               path: :embedding,
               host: "api.somewhere.com",
               base_url: "https://api.somewhere.com/v1",
               locality: :remote
             }
           ]
  end

  test "a remote embedding endpoint counts even while chat stays local" do
    configure("http://localhost:8000", "https://api.somewhere.com")

    refute Inference.local?()
    assert Inference.remote_hosts() == ["api.somewhere.com"]
    assert Inference.destination_label() == "api.somewhere.com"

    assert [
             %{path: :chat, host: "localhost", locality: :local},
             %{path: :embedding, host: "api.somewhere.com", locality: :remote}
           ] = Inference.endpoints()
  end

  test "two remote endpoints are both named, deduplicated and sorted" do
    configure("https://chat.example.com", "https://api.somewhere.com")

    refute Inference.local?()
    assert Inference.remote_hosts() == ["api.somewhere.com", "chat.example.com"]
    assert Inference.destination_label() == "api.somewhere.com, chat.example.com"
  end

  test "the same remote host reached by two paths is named once" do
    configure("https://same.example.com", "https://same.example.com/v1")

    assert Inference.remote_hosts() == ["same.example.com"]
    assert Inference.destination_label() == "same.example.com"
  end

  test "an unset embedding endpoint inherits the chat host's locality" do
    configure("http://localhost:8000", nil)

    assert Inference.local?()
    assert [_chat, %{path: :embedding, host: "localhost"}] = Inference.endpoints()

    configure("https://api.somewhere.com", nil)

    refute Inference.local?()
    assert Inference.remote_hosts() == ["api.somewhere.com"]
  end

  test "the loopback spellings are local" do
    for host <- ["localhost", "127.0.0.1", "[::1]", "0.0.0.0", "LocalHost"] do
      configure("http://#{host}:8000", nil)

      assert Inference.local?(), "expected #{host} to be local"
      assert Inference.remote_hosts() == []
      assert Inference.destination_label() == ""
    end
  end

  test "the Docker gateway back to the host machine is local, not a third party" do
    # Both are the user's own machine reached from inside a container, and
    # host.docker.internal:8000 is this project's shipped docker-compose default.
    for host <- ["host.docker.internal", "172.17.0.1"] do
      configure("http://#{host}:8000", nil)

      assert Inference.local?(), "expected #{host} to be local"
      assert Inference.remote_hosts() == []
    end
  end

  test "a base URL with no readable host is not local and names nothing" do
    for base_url <- ["llm:8000", "", "http://", "not a url", :localhost] do
      configure(base_url, nil)

      refute Inference.local?(), "expected #{inspect(base_url)} to be treated as not local"
      assert Inference.remote_hosts() == []
      assert [%{locality: :unknown, host: nil} | _] = Inference.endpoints()
    end
  end

  test "an unreadable endpoint still labels a destination, falling back to the URL" do
    configure("llm:8000", nil)

    refute Inference.local?()
    assert Inference.remote_hosts() == []
    assert Inference.destination_label() == "llm:8000"
  end

  test "an unreadable endpoint with nothing renderable still labels something" do
    for base_url <- ["", "   ", :localhost] do
      configure(base_url, nil)

      label = Inference.destination_label()

      refute Inference.local?()
      assert String.trim(label) != "", "expected #{inspect(base_url)} to yield a label"
    end
  end

  test "an unreadable endpoint alongside a remote one names both" do
    configure("llm:8000", "https://api.somewhere.com")

    refute Inference.local?()
    assert Inference.remote_hosts() == ["api.somewhere.com"]
    assert Inference.destination_label() == "api.somewhere.com, llm:8000"
  end

  test "locality/1 applies the same rule to an endpoint held by the caller" do
    assert Inference.locality("http://127.0.0.1:8000") == :local
    assert Inference.locality("http://host.docker.internal:8000") == :local
    assert Inference.locality("https://api.somewhere.com") == :remote
    assert Inference.locality("llm:8000") == :unknown
    assert Inference.locality(nil) == :unknown
  end

  test "credentials in a base URL never reach the label or the endpoints" do
    configure("http://user:s3cret@api.somewhere.com:8000", nil)

    label = Inference.destination_label()

    assert label == "api.somewhere.com"
    refute label =~ "s3cret"

    rendered = inspect(Inference.endpoints())
    refute rendered =~ "s3cret"
    assert [%{base_url: "http://api.somewhere.com:8000"} | _] = Inference.endpoints()
  end

  test "the API key never surfaces and does not decide locality" do
    Application.put_env(:doctrans, :openai,
      base_url: "http://localhost:8000",
      api_key: "secret-chat-key",
      chat_model: "chat"
    )

    Application.put_env(:doctrans, :embedding, base_url: nil, api_key: "secret-embedding-key")

    # A local server may still demand a bearer token; that is not egress.
    assert Inference.local?()

    refute Inference.endpoints() |> inspect() |> String.contains?("secret")
    refute Inference.destination_label() =~ "secret"
  end
end
