defmodule Doctrans.Processing.OllamaStub do
  @moduledoc """
  Stub implementation of OllamaBehaviour for tests.

  Returns fake responses that can be used in tests without
  requiring the actual Ollama service.

  ## Configuration

  You can configure stub behavior per-test using Application.put_env:

      # Simulate extraction error
      Application.put_env(:doctrans, :ollama_stub_extraction_error, "error message")

      # Simulate translation error
      Application.put_env(:doctrans, :ollama_stub_translation_error, :circuit_open)

      # Reset to default behavior
      Application.delete_env(:doctrans, :ollama_stub_extraction_error)
  """

  @behaviour Doctrans.Processing.OllamaBehaviour

  @impl true
  def extract_markdown(image_path, opts \\ [])

  def extract_markdown(_image_path, _opts) do
    case Application.get_env(:doctrans, :ollama_stub_extraction_error) do
      nil ->
        {:ok,
         "# Extracted Test Content\n\nThis is mock markdown content extracted from the image."}

      error ->
        {:error, error}
    end
  end

  @impl true
  def translate(markdown, target_language, opts \\ [])

  def translate(markdown, target_language, _opts) do
    case Application.get_env(:doctrans, :ollama_stub_translation_error) do
      nil -> {:ok, "# Translated to #{target_language}\n\n#{markdown}"}
      error -> {:error, error}
    end
  end

  @impl true
  def available? do
    not Application.get_env(:doctrans, :ollama_stub_unavailable, false)
  end

  @impl true
  def list_models do
    case Application.get_env(:doctrans, :ollama_stub_models_error) do
      nil -> {:ok, ["qwen2.5-vl:latest", "qwen3:14b"]}
      error -> {:error, error}
    end
  end
end
