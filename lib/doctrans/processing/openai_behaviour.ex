defmodule Doctrans.Processing.OpenAIBehaviour do
  @moduledoc """
  Behaviour for OpenAI-compatible API interactions.

  This allows mocking the API service in tests.
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

  @callback chat_stream(
              messages :: [map()],
              on_delta :: (String.t() -> any()),
              opts :: keyword()
            ) ::
              {:ok, String.t()} | {:error, term()}
end
