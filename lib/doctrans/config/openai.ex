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

  @doc """
  Per-receive timeout in milliseconds; defaults to five minutes.

  This is what Req resets on every chunk that arrives, so on its own it bounds
  silence, not the call. `deadline/0` bounds the call.
  """
  @spec timeout() :: pos_integer()
  def timeout, do: Config.get(:openai, :timeout) || 300_000

  @doc """
  Total wall-clock budget for one API call, retries included, in milliseconds;
  defaults to ten minutes.
  """
  @spec deadline() :: pos_integer()
  def deadline, do: Config.get(:openai, :deadline) || 600_000

  @doc """
  Largest response body accepted from the API, in bytes; defaults to 8 MB.

  A completion capped at a few thousand tokens is three orders of magnitude
  below this; the bound exists so a broken or hostile endpoint cannot stream
  the node out of memory.
  """
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: Config.get(:openai, :max_response_bytes) || 8_000_000
end
