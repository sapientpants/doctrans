defmodule Doctrans.Processing.OllamaStub do
  @moduledoc """
  Stub implementation of OllamaBehaviour for tests.

  Returns fake responses that can be used in tests without
  requiring the actual Ollama service.
  """

  @behaviour Doctrans.Processing.OllamaBehaviour

  @impl true
  def extract_markdown(image_path, opts \\ [])

  def extract_markdown(_image_path, _opts) do
    {:ok, "# Extracted Test Content\n\nThis is mock markdown content extracted from the image."}
  end

  @impl true
  def translate(markdown, target_language, opts \\ [])

  def translate(markdown, target_language, _opts) do
    {:ok, "# Translated to #{target_language}\n\n#{markdown}"}
  end

  @impl true
  def available? do
    true
  end

  @impl true
  def list_models do
    {:ok, ["qwen2.5-vl:latest", "qwen3:14b"]}
  end
end
