defmodule Doctrans.Search.Embedding do
  @moduledoc """
  Generates text embeddings using an OpenAI-compatible embedding API.

  Output is truncated to 1024 dimensions using Matryoshka Representation
  Learning (MRL) — the first N dimensions carry the most information.

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
    config = embedding_config()
    model = Keyword.get(opts, :model, config[:model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])
    api_key = config[:api_key]

    body = %{
      model: model,
      input: text
    }

    url = "#{config[:base_url]}/v1/embeddings"

    Logger.debug(
      "Embedding POST #{url}, model: #{model}, api_key: #{if(api_key, do: "<set>", else: "<none>")}"
    )

    request =
      case api_key do
        nil ->
          Req.post(url, json: body, receive_timeout: timeout)

        key ->
          Req.post(url,
            json: body,
            receive_timeout: timeout,
            headers: [{"authorization", "Bearer #{key}"}]
          )
      end

    case request do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding}]}}} ->
        if length(embedding) >= @embedding_dimensions do
          # Truncate to @embedding_dimensions for Matryoshka models that output
          # more dimensions than we store (e.g., 4096 -> 1024)
          truncated = Enum.take(embedding, @embedding_dimensions)
          {:ok, Pgvector.new(truncated)}
        else
          Logger.error(
            "OpenAI embedding too short: expected at least #{@embedding_dimensions} dimensions, got #{length(embedding)}"
          )

          {:error,
           dgettext(
             "errors",
             "OpenAI embedding too short: expected at least %{expected} dimensions, got %{actual}",
             expected: @embedding_dimensions,
             actual: length(embedding)
           )}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI embedding error (#{status}): #{inspect(body)}")

        {:error,
         dgettext("errors", "OpenAI embedding error (%{status}): %{body}",
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
