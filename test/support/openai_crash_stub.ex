defmodule Doctrans.Processing.OpenAICrashStub do
  @moduledoc """
  Mock implementation of OpenAIBehaviour that crashes during extraction, for
  tests covering job failures that never return a result to Oban.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

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

  @impl true
  def available?, do: true

  @impl true
  def list_models, do: {:ok, ["crash-stub-model"]}
end
