defmodule Doctrans.Processing.UnslothStub do
  @moduledoc """
  Stub implementation of ProviderBehaviour for Unsloth tests.

  Returns fake responses that can be used in tests without
  requiring the actual Unsloth service.

  ## Configuration

  You can configure stub behavior per-test using Application.put_env:

      # Simulate extraction error
      Application.put_env(:doctrans, :unsloth_stub_extraction_error, "error message")

      # Simulate translation error
      Application.put_env(:doctrans, :unsloth_stub_translation_error, :circuit_open)

      # Reset to default behavior
      Application.delete_env(:doctrans, :unsloth_stub_extraction_error)
  """

  @behaviour Doctrans.Processing.ProviderBehaviour

  @impl true
  def extract_markdown(_image_path, _opts) do
    case Application.get_env(:doctrans, :unsloth_stub_extraction_error) do
      nil ->
        {:ok,
         "# Extracted Test Content\n\nThis is mock markdown content extracted from the image."}

      error ->
        {:error, error}
    end
  end

  @impl true
  def translate(markdown, _source_language, target_language, _opts) do
    case Application.get_env(:doctrans, :unsloth_stub_translation_error) do
      nil -> {:ok, "# Translated to #{target_language}\n\n#{markdown}"}
      error -> {:error, error}
    end
  end

  @impl true
  def available? do
    not Application.get_env(:doctrans, :unsloth_stub_unavailable, false)
  end

  @impl true
  def list_models do
    case Application.get_env(:doctrans, :unsloth_stub_models_error) do
      nil -> {:ok, ["unsloth/Qwen3.5-9B-MTP-GGUF", "unsloth/Qwen3.6-35B-A3B-MTP-GGUF"]}
      error -> {:error, error}
    end
  end

  @impl true
  def chat(messages, _opts) do
    case Application.get_env(:doctrans, :unsloth_stub_chat_error) do
      nil ->
        user_msg =
          messages
          |> Enum.filter(fn msg ->
            role = Map.get(msg, :role) || Map.get(msg, "role")
            role == "user"
          end)
          |> List.last()

        question =
          case user_msg do
            nil -> "unknown question"
            msg -> Map.get(msg, :content) || Map.get(msg, "content") || "unknown question"
          end

        {:ok,
         "This is a mock response to your question about: #{String.slice(question, 0, 50)}. The document contains relevant information."}

      error ->
        {:error, error}
    end
  end
end
