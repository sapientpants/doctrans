defmodule Doctrans.Processing.OpenAICrashStub do
  @moduledoc """
  Mock implementation of OpenAIBehaviour that crashes during extraction, for
  tests covering job failures that never return a result to Oban.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  alias Doctrans.Processing.OpenAIStub

  @impl true
  def chat(_messages, _opts), do: {:ok, "crash stub"}

  @impl true
  def chat_stream(_messages, on_delta, _opts) do
    on_delta.("crash stub")
    {:ok, "crash stub"}
  end

  @impl true
  def extract_markdown(_image_path, _opts), do: raise("extraction crashed")

  @impl true
  def translate(_markdown, _source_language, _target_language, _opts),
    do: raise("translation crashed")

  # Detection is not what this stub exists to fail, and a raising clause here
  # would be unreachable anyway: detection only runs for a document with no
  # source language, and the fixtures set one. Delegating keeps it honest
  # instead of spending a permanent Dialyzer suppression on dead code.
  @impl true
  def detect_language(markdown, opts), do: OpenAIStub.detect_language(markdown, opts)

  @impl true
  def available?, do: true

  @impl true
  def list_models, do: {:ok, ["crash-stub-model"]}
end
