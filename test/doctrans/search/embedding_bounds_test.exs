defmodule Doctrans.Search.EmbeddingBoundsTest do
  @moduledoc """
  The per-call `:deadline` option of `Doctrans.Search.Embedding.generate/2`.

  The indexer runs a page under a budget and hands each call what is left of
  it; this holds that the option, not the configured deadline, is the bound
  that fires. The endpoint is a raw TCP server that accepts the request and
  says nothing, as in `Doctrans.Processing.OpenAIBoundsTest`, because a plug
  server cannot be shut down cleanly underneath a stalled call.

  `async: false`: the `:embedding` application environment is mutated and
  restored, and the `:embedding_api` fuse is shared.
  """
  use Doctrans.EnvCase, async: false

  @moduletag :capture_log

  alias Doctrans.Search.Embedding
  alias Doctrans.TestEnv

  @deadline 300
  # Five times the deadline, so the assertion catches an unbounded call rather
  # than a slow machine.
  @bounded_ms 1_500

  setup do
    TestEnv.reset_fuses()
  end

  test "an explicit deadline bounds the call under a far wider configured one" do
    start_stalling_endpoint()

    {microseconds, result} =
      :timer.tc(fn -> Embedding.generate("some text", deadline: @deadline) end)

    assert result == {:error, :inference_deadline_exceeded}
    assert div(microseconds, 1000) < @bounded_ms
  end

  defp start_stalling_endpoint do
    parent = self()

    server =
      spawn(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        send(parent, {:endpoint_port, port})
        {:ok, _socket} = :gen_tcp.accept(listen)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)

    receive do
      {:endpoint_port, port} ->
        TestEnv.put_env(:embedding,
          base_url: "http://127.0.0.1:#{port}",
          api_key: nil,
          model: "test-embedding-model",
          # Far above the option on purpose: the option is what bounds the call.
          timeout: 60_000,
          deadline: 60_000
        )
    after
      5_000 -> flunk("fake endpoint did not start")
    end
  end
end
