defmodule Doctrans.Search.Embedding do
  @moduledoc """
  Generates text embeddings using Ollama's embedding API.

  Uses qwen3-embedding:0.6b model which outputs 1024-dimensional vectors.

  ## I18n Note

  This module runs in background GenServer processes (embedding workers),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  @doc """
  Generates an embedding vector for the given text.

  Returns `{:ok, [float()]}` on success or `{:error, reason}` on failure.
  Returns `{:ok, nil}` for nil or empty text.
  """
  def generate(text, opts \\ [])
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}

  def generate(text, opts) when is_binary(text) do
    config = embedding_config()
    model = Keyword.get(opts, :model, config[:model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    body = %{
      model: model,
      input: text
    }

    url = "#{config[:base_url]}/api/embed"

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        {:ok, Pgvector.new(embedding)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama embedding error (#{status}): #{inspect(body)}")

        {:error,
         dgettext("errors", "Ollama embedding error (%{status}): %{body}",
           status: status,
           body: inspect(body)
         )}

      {:error, reason} ->
        Logger.error("Embedding request failed: #{inspect(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: inspect(reason))}
    end
  end

  defp embedding_config do
    Application.get_env(:doctrans, :embedding, [])
  end
end
