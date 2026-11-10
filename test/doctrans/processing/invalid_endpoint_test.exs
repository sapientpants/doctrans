defmodule Doctrans.Processing.InvalidEndpointTest do
  @moduledoc """
  A base URL without an http(s) scheme or a host never reaches Req.

  Finch refuses such a URL by raising an `ArgumentError` whose message quotes the
  URL whole, credentials included, and the clients log and store exception
  messages unredacted (#266). `config/runtime.exs` refuses `OPENAI_HOST` at boot;
  this covers the net under it, for a base URL that arrived any other way: the
  call fails as an ordinary `{:error, :invalid_endpoint_url}`, and the secret
  appears nowhere in the log.

  `async: false`: the `:doctrans` application environment is mutated and
  restored, and the fuses are shared.
  """
  use Doctrans.EnvCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Doctrans.Processing.OpenAI
  alias Doctrans.Resilience.ErrorClassifier
  alias Doctrans.Search.Embedding
  alias Doctrans.TestEnv
  alias DoctransWeb.ErrorMessages

  @secret "hunter2"
  # The operator forgot the scheme: the shape the issue reproduced.
  @scheme_less "user:#{@secret}@gateway.internal:8000"
  # The operator lost the host: Finch raises "host is required" with the URL.
  @host_less "http://user:#{@secret}@/v1"

  setup do
    TestEnv.reset_fuses()
    :ok
  end

  defp configure(key, base_url), do: TestEnv.merge_env(key, base_url: base_url)

  defp without_leaking_secret(fun) do
    {result, log} = with_log(fun)
    refute log =~ @secret, "the credential reached the log: #{log}"
    result
  end

  for {label, url} <- [scheme_less: @scheme_less, host_less: @host_less] do
    describe "a #{label} chat base URL" do
      setup do
        configure(:openai, unquote(url))
        :ok
      end

      test "fails a completion as an ordinary error, without raising" do
        assert without_leaking_secret(fn -> OpenAI.chat([%{role: "user", content: "hi"}]) end) ==
                 {:error, :invalid_endpoint_url}
      end

      test "fails a stream before any delta" do
        result =
          without_leaking_secret(fn ->
            OpenAI.chat_stream([%{role: "user", content: "hi"}], &send(self(), {:delta, &1}))
          end)

        assert result == {:error, :invalid_endpoint_url}
        refute_received {:delta, _}
      end

      test "fails the model list the health probe and the reprocess modal ask for" do
        assert without_leaking_secret(&OpenAI.list_models/0) == {:error, :invalid_endpoint_url}
      end
    end
  end

  describe "a malformed embedding base URL" do
    test "fails an embedding as an ordinary error, without raising" do
      configure(:embedding, @scheme_less)

      assert without_leaking_secret(fn -> Embedding.generate("some chunk text") end) ==
               {:error, :invalid_endpoint_url}
    end

    # The embedding endpoint falls back to the chat one when unset, so the
    # misconfiguration follows it there.
    test "follows the chat base URL when its own is unset" do
      configure(:openai, @scheme_less)
      configure(:embedding, nil)

      assert without_leaking_secret(fn -> Embedding.generate("some chunk text") end) ==
               {:error, :invalid_endpoint_url}
    end
  end

  # Configuration does not change between attempts, so a retry only repeats the
  # failure; and the user is told which setting to fix rather than shown the
  # generic message.
  test "the reason is permanent and has a message naming the setting" do
    assert ErrorClassifier.classify(:invalid_endpoint_url) == :permanent
    assert ErrorMessages.message(:invalid_endpoint_url) =~ "OPENAI_HOST"
  end
end
