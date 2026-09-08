defmodule Doctrans.Config.OpenAI do
  @moduledoc "Typed runtime settings for the OpenAI-compatible API."

  alias Doctrans.Config

  @spec base_url() :: String.t()
  def base_url, do: Config.fetch!(:openai, :base_url)

  @spec api_key() :: String.t() | nil
  def api_key, do: Config.get(:openai, :api_key)

  @spec vision_model() :: String.t()
  def vision_model, do: Config.get(:openai, :vision_model) || Config.fetch!(:openai, :chat_model)

  @spec chat_model() :: String.t()
  def chat_model, do: Config.get(:openai, :chat_model) || Config.fetch!(:openai, :vision_model)

  @spec translation_model() :: String.t()
  def translation_model, do: Config.get(:openai, :translation_model) || chat_model()

  @doc "Request timeout in milliseconds; defaults to five minutes."
  @spec timeout() :: pos_integer()
  def timeout, do: Config.get(:openai, :timeout) || 300_000
end
