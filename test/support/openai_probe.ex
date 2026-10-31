defmodule Doctrans.Processing.OpenAIProbe do
  @moduledoc """
  An `OpenAIMock` stub that records the options of every call, for tests
  asserting per-stage behaviour (e.g. the thinking toggle).

  `install/0` stubs every callback on `Doctrans.Processing.OpenAIMock` for the
  running test. Each call sends `{function, opts}` to the test process and
  returns a canned successful response; `chat/2` also sends
  `{:chat_messages, messages}`, `chat_stream/3` sends
  `{:chat_stream_messages, messages}`, and `translate/4` additionally sends
  `{:translate_languages, {source_language, target_language}}`, so a test can
  assert which languages a document was actually translated between.
  """

  import Mox

  alias Doctrans.Processing.OpenAIMock

  @doc """
  Records every `OpenAIMock` call to the calling test process.
  """
  def install do
    owner = self()

    stub(OpenAIMock, :chat, fn messages, opts ->
      record(owner, :chat, opts)
      record(owner, :chat_messages, messages)
      {:ok, "probe response"}
    end)

    stub(OpenAIMock, :chat_stream, fn messages, on_delta, opts ->
      record(owner, :chat_stream, opts)
      record(owner, :chat_stream_messages, messages)

      response = "probe stream"
      [first, rest] = [String.slice(response, 0, 5), String.slice(response, 5..-1//1)]
      on_delta.(first)
      on_delta.(rest)

      {:ok, response}
    end)

    stub(OpenAIMock, :extract_markdown, fn _image_path, opts ->
      record(owner, :extract_markdown, opts)
      {:ok, "# Probe markdown"}
    end)

    stub(OpenAIMock, :translate, fn _markdown, source_language, target_language, opts ->
      record(owner, :translate, opts)
      record(owner, :translate_languages, {source_language, target_language})
      {:ok, "probe translation #{target_language}"}
    end)

    stub(OpenAIMock, :detect_language, fn _markdown, opts ->
      record(owner, :detect_language, opts)
      {:ok, "de"}
    end)

    stub(OpenAIMock, :list_models, fn -> {:ok, ["probe-model"]} end)

    :ok
  end

  defp record(owner, function, payload), do: send(owner, {function, payload})
end
