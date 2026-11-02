defmodule Doctrans.Search.Embedding do
  @moduledoc """
  Generates text embeddings against an OpenAI-compatible embedding API.

  The embedding endpoint is configured apart from the chat one
  (`Doctrans.Config.Embedding`), guarded by its own `:embedding_api` fuse, and
  bounded by `Doctrans.Processing.RequestBounds` like every other model call.
  Every response is settled by `Doctrans.Processing.ApiFailure.resolve/4`, so
  a failure is logged, classified and normalized in one place.

  Vectors are truncated to `dimensions/0` entries, the width of the stored
  column: a Matryoshka model that answers wider is cut down, and a model that
  answers narrower is rejected as `{:embedding_too_short, _}`.

  Errors are locale-independent reasons, translated only by the web layer.
  """

  @behaviour Doctrans.Search.EmbeddingBehaviour

  alias Doctrans.Config.{Embedding, Inference}
  alias Doctrans.Processing.{ApiFailure, RequestBounds}
  alias Doctrans.Resilience.CircuitBreaker

  require Logger

  @dimensions 1024

  @doc "The width of a stored vector, which every embedding is truncated to."
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  @doc """
  Generates an embedding vector for the given text.

  Returns `{:ok, embedding}` on success or `{:error, reason}` on failure.
  Returns `{:ok, nil}` for nil or empty text.

  The ask lives next to the melt, so every caller -- indexer, search, chat
  retrieval -- is held off a blown `:embedding_api` fuse without wrapping the
  call itself. The fuse is only asked here; `ApiFailure` classifies each
  failure and melts for the ones that count.
  """
  @impl true
  def generate(text, opts \\ [])
  def generate(nil, _opts), do: {:ok, nil}
  def generate("", _opts), do: {:ok, nil}

  def generate(text, opts) when is_binary(text) do
    CircuitBreaker.call(:embedding_api, fn -> embed(text, opts) end)
  end

  defp embed(text, opts) do
    model = Keyword.get(opts, :model) || Embedding.model()
    timeout = Keyword.get(opts, :timeout) || Embedding.timeout()
    url = api_url("/v1/embeddings")

    # The base URL is operator-supplied and may carry credentials, and this line
    # is written before Req ever sees the URL; `Inference` owns the redaction.
    Logger.debug(
      "Embedding POST #{Inference.redact_url(url)}, model: #{model}, api_key: #{if(Embedding.api_key(), do: "<set>", else: "<none>")}"
    )

    build_base_req()
    |> RequestBounds.post(bounds(timeout),
      url: url,
      json: %{model: model, input: text},
      # Embedding POSTs are idempotent; replay them on transient failures
      retry: :transient,
      # An embedding request carries the chunk text it is embedding, so a
      # followed redirect is document egress: see the chat client's
      # `post_chat_completion/2`.
      redirect: false
    )
    |> ApiFailure.resolve(:embedding_api, &parse_response/1)
  end

  defp parse_response(%{"data" => [%{"embedding" => embedding}]}) when is_list(embedding) do
    if length(embedding) >= @dimensions do
      {:ok, Pgvector.new(Enum.take(embedding, @dimensions))}
    else
      {:error, {:embedding_too_short, [expected: @dimensions, actual: length(embedding)]}}
    end
  end

  defp parse_response(_body), do: {:error, :invalid_embedding_response}

  defp api_url(path) do
    "#{Embedding.base_url()}/#{String.trim_leading(path, "/")}"
  end

  # Embeddings read the `:embedding` section, so a search box can be bounded on
  # its own. Only `:timeout` differs by default -- a minute against five, spending
  # the same total budget in shorter attempts until a deadline is set there.
  defp bounds(timeout) do
    RequestBounds.new(
      timeout: timeout,
      deadline: Embedding.deadline(),
      max_response_bytes: Embedding.max_response_bytes()
    )
  end

  # No key, no header: an absent credential is not an empty one.
  defp build_base_req do
    case Embedding.api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end
end
