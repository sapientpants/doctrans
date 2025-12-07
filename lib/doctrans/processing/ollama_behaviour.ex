defmodule Doctrans.Processing.OllamaBehaviour do
  @moduledoc """
  Behaviour for Ollama API interactions.

  This allows mocking the Ollama service in tests.
  """

  @callback extract_markdown(image_path :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback translate(markdown :: String.t(), target_language :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback available?() :: boolean()

  @callback list_models() :: {:ok, [String.t()]} | {:error, term()}
end
