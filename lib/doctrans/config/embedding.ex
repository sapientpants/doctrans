defmodule Doctrans.Config.Embedding do
  @moduledoc "Typed runtime settings for embeddings, with a shared OpenAI endpoint by default."

  alias Doctrans.Config
  alias Doctrans.Config.OpenAI

  @spec base_url() :: String.t()
  def base_url, do: Config.get(:embedding, :base_url) || OpenAI.base_url()

  @spec api_key() :: String.t() | nil
  def api_key, do: Config.get(:embedding, :api_key)

  @spec model() :: String.t()
  def model, do: Config.get(:embedding, :model) || OpenAI.chat_model()

  @doc "Request timeout in milliseconds; defaults to one minute."
  @spec timeout() :: pos_integer()
  def timeout, do: Config.get(:embedding, :timeout) || 60_000
end
