defmodule Doctrans.Processing.OpenAIStub do
  @moduledoc """
  The default `Doctrans.Processing.OpenAIBehaviour` stub.

  Returns fake responses, so tests exercise the processing and chat code paths
  without the model server. `Doctrans.Mocks.setup/1` installs it on
  `Doctrans.Processing.OpenAIMock` for every test, and a test that needs one
  call to fail, or a particular model list or detected language, narrows the
  mock for that function alone:

      Mox.stub(OpenAIMock, :extract_markdown, fn _image_path, _opts -> {:error, :timeout} end)
      Mox.stub(OpenAIMock, :list_models, fn -> {:ok, ["my-model"]} end)

  A test that needs every call recorded installs `Doctrans.Processing.OpenAIProbe`.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  @default_models [
    "mlx-community/Qwen3.6-35B-A3B-4bit",
    "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"
  ]

  @doc "The model list `list_models/0` answers with."
  def default_models, do: @default_models

  @impl true
  def extract_markdown(_image_path, _opts) do
    {:ok, "# Extracted Test Content\n\nThis is mock markdown content extracted from the image."}
  end

  @impl true
  def translate(markdown, source_language, target_language, _opts) do
    {:ok, "# Translated #{source_language} to #{target_language}\n\n#{markdown}"}
  end

  @impl true
  def detect_language(_markdown, _opts), do: {:ok, "de"}

  @impl true
  def available?, do: true

  @impl true
  def list_models, do: {:ok, @default_models}

  @impl true
  def chat(messages, _opts) do
    # Handle both atom keys (%{role: "user"}) and string keys (%{"role" => "user"})
    user_msg =
      messages
      |> Enum.filter(fn msg -> Map.get(msg, :role) || Map.get(msg, "role") == "user" end)
      |> List.last()

    content =
      case user_msg do
        nil -> "unknown question"
        msg -> Map.get(msg, :content) || Map.get(msg, "content") || "unknown question"
      end

    {:ok,
     "This is a mock response to your question about: #{String.slice(content, 0, 50)}. The document contains relevant information."}
  end

  @impl true
  def chat_stream(messages, on_delta, opts) do
    {:ok, response} = chat(messages, opts)

    # Emit the mock response in chunks to exercise streaming.
    chunk_size = max(1, div(String.length(response), 3))

    response
    |> String.graphemes()
    |> Enum.chunk_every(chunk_size)
    |> Enum.each(fn chunk -> on_delta.(Enum.join(chunk)) end)

    {:ok, response}
  end
end
