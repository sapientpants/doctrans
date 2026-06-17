defmodule Doctrans.Processing.OllamaBehaviour do
  @moduledoc """
  Legacy alias for ProviderBehaviour.

  Kept for backward compatibility with existing test mocks. New code should
  use `Doctrans.Processing.ProviderBehaviour` directly.
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
