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

  @doc "Per-receive timeout in milliseconds; defaults to one minute."
  @spec timeout() :: pos_integer()
  def timeout, do: Config.get(:embedding, :timeout) || 60_000

  @doc "Total budget for one embedding call, retries included; defaults to the API setting."
  @spec deadline() :: pos_integer()
  def deadline, do: Config.get(:embedding, :deadline) || OpenAI.deadline()

  @doc "Largest embedding response accepted, in bytes; defaults to the API setting."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes,
    do: Config.get(:embedding, :max_response_bytes) || OpenAI.max_response_bytes()
end
