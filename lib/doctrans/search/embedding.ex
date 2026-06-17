defmodule Doctrans.Search.Embedding do
  @moduledoc """
  Generates text embeddings using the active provider's embedding API.

  Output is truncated to 1024 dimensions using Matryoshka Representation
  Learning (MRL) — the first N dimensions carry the most information.

  The provider and model are resolved from `:provider_module` config, so
  switching providers automatically switches the embedding source.

  ## I18n Note

  This module runs in background GenServer processes (embedding workers),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
  """

  @embedding_dimensions 1024

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
    config = provider_embedding_config()
    model = Keyword.get(opts, :model, config[:embedding_model])
    base_url = config[:base_url]
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    body = %{
      model: model,
      input: text
    }

    url = "#{base_url}/api/embed"

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        if length(embedding) >= @embedding_dimensions do
          truncated = Enum.take(embedding, @embedding_dimensions)
          {:ok, Pgvector.new(truncated)}
        else
          Logger.error(
            "Embedding too short: expected at least #{@embedding_dimensions} dimensions, got #{length(embedding)}"
          )

          {:error,
           dgettext(
             "errors",
             "Embedding too short: expected at least %{expected} dimensions, got %{actual}",
             expected: @embedding_dimensions,
             actual: length(embedding)
           )}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Embedding error (#{status}): #{inspect(body)}")

        {:error,
         dgettext("errors", "Embedding error (%{status}): %{body}",
           status: status,
           body: inspect(body)
         )}

      {:error, reason} ->
        Logger.error("Embedding request failed: #{inspect(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: inspect(reason))}
    end
  end

  defp provider_embedding_config do
    provider_module = Application.get_env(:doctrans, :provider_module, Doctrans.Processing.Ollama)
    config_key = provider_to_config_key(provider_module)
    Application.get_env(:doctrans, config_key, [])
  end

  defp provider_to_config_key(Doctrans.Processing.Ollama), do: :ollama
  defp provider_to_config_key(Doctrans.Processing.Unsloth), do: :unsloth
  defp provider_to_config_key(_), do: :ollama
end
