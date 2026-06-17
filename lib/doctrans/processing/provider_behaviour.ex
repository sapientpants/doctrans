defmodule Doctrans.Processing.ProviderBehaviour do
  @moduledoc """
  Shared behaviour for LLM provider modules.

  Both Ollama and Unsloth implement this contract, allowing callers to work
  with either provider through a single interface.
  """

  @callback extract_markdown(image_path :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback translate(
              markdown :: String.t(),
              source_language :: String.t(),
              target_language :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, String.t()} | {:error, term()}

  @callback available?() :: boolean()

  @callback list_models() :: {:ok, [String.t()]} | {:error, term()}

  @callback chat(messages :: [map()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
