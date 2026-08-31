defmodule Doctrans.Processing.OpenAIStub do
  @moduledoc """
  Mock implementation of OpenAIBehaviour for tests.

  Returns fake responses that can be used in tests without
  requiring the actual API service.

  ## Configuration

  You can configure mock behavior per-test using Application.put_env:

      # Simulate extraction error
      Application.put_env(:doctrans, :openai_stub_extraction_error, "error message")

      # Simulate translation error
      Application.put_env(:doctrans, :openai_stub_translation_error, :circuit_open)

      # Reset to default behavior
      Application.delete_env(:doctrans, :openai_stub_extraction_error)
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  @impl true
  def extract_markdown(image_path, opts \\ [])

  def extract_markdown(_image_path, _opts) do
    case Application.get_env(:doctrans, :openai_stub_extraction_error) do
      nil ->
        {:ok,
         "# Extracted Test Content\n\nThis is mock markdown content extracted from the image."}

      error ->
        {:error, error}
    end
  end

  @impl true
  def translate(markdown, source_language, target_language, opts \\ [])

  def translate(markdown, _source_language, target_language, _opts) do
    case Application.get_env(:doctrans, :openai_stub_translation_error) do
      nil -> {:ok, "# Translated to #{target_language}\n\n#{markdown}"}
      error -> {:error, error}
    end
  end

  @impl true
  def available? do
    not Application.get_env(:doctrans, :openai_stub_unavailable, false)
  end

  @impl true
  def list_models do
    case Application.get_env(:doctrans, :openai_stub_models) do
      nil ->
        {:ok, ["mlx-community/Qwen3.6-35B-A3B-4bit", "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"]}

      error ->
        {:error, error}
    end
  end

  @impl true
  def chat(messages, opts \\ [])

  def chat(messages, _opts) do
    case Application.get_env(:doctrans, :openai_stub_chat_error) do
      nil ->
        # Handle both atom keys (%{role: "user"}) and string keys (%{"role" => "user"})
        user_msg =
          messages
          |> Enum.filter(fn msg ->
            Map.get(msg, :role) || Map.get(msg, "role") == "user"
          end)
          |> List.last()

        content =
          case user_msg do
            nil ->
              "unknown question"

            msg ->
              Map.get(msg, :content) || Map.get(msg, "content") || "unknown question"
          end

        {:ok,
         "This is a mock response to your question about: #{String.slice(content, 0, 50)}. The document contains relevant information."}

      error ->
        {:error, error}
    end
  end

  @impl true
  def chat_stream(messages, on_delta, opts \\ [])

  def chat_stream(messages, on_delta, opts) do
    case chat(messages, opts) do
      {:ok, response} ->
        # Emit the mock response in chunks to exercise streaming.
        chunk_size = max(1, div(String.length(response), 3))

        response
        |> String.graphemes()
        |> Enum.chunk_every(chunk_size)
        |> Enum.each(fn chunk ->
          on_delta.(Enum.join(chunk))
        end)

        {:ok, response}

      error ->
        error
    end
  end

  def embed(_text, _opts) do
    # Return a vector of 1024 dimensions (truncated from native 4096)
    vector = Enum.map(1..1024, fn _i -> :rand.uniform() * 2 - 1 end)
    {:ok, vector}
  end
end
