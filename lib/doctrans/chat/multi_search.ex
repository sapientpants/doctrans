defmodule Doctrans.Chat.MultiSearch do
  @moduledoc """
  Searches a document with multiple query variants and merges results via
  Reciprocal Rank Fusion (RRF).

  Each query is embedded and searched independently in parallel. Results are
  deduplicated by page and chunk index and scored using RRF to surface results that rank highly
  across multiple query phrasings.
  """

  alias Doctrans.Errors
  alias Doctrans.Search

  require Logger

  @rrf_k 60

  @doc """
  Searches a document using multiple query strings and returns merged results.

  Generates embeddings for all queries in parallel, runs pgvector searches,
  and merges results using Reciprocal Rank Fusion.

  A query that fails is logged and skipped, so a partially available retrieval
  still answers with what it found. Returns `{:error, {:retrieval_unavailable,
  [reason: reason]}}` only when *every* query failed, which is an outage rather
  than an absence of matches: `{:ok, []}` means the document was searched and
  nothing matched. An empty query list is `{:ok, []}` too — nothing was asked,
  so nothing failed.

  ## Options

  - `:limit` - Maximum number of results to return (default: 3)
  - `:min_similarity` - Minimum cosine similarity threshold (default: Search default)
  """
  @spec search_with_queries(Ecto.UUID.t(), [String.t()], keyword()) ::
          {:ok, [Search.document_result()]} | {:error, Errors.reason()}
  def search_with_queries(document_id, queries, opts \\ [])

  def search_with_queries(_document_id, [], _opts), do: {:ok, []}

  def search_with_queries(document_id, queries, opts) when is_list(queries) do
    limit = Keyword.get(opts, :limit, 3)

    document_id
    |> query_outcomes(queries, per_query_opts(opts, limit))
    |> Enum.split_with(&match?({:ok, _results}, &1))
    |> resolve(queries, limit)
  end

  # Task.async_stream preserves input order, so the head of the failures is the
  # first query's failure.
  defp resolve({[], [{:error, reason} | _rest] = failures}, queries, _limit) do
    log_summary(queries, [], failures, 0)

    {:error, {:retrieval_unavailable, [reason: reason]}}
  end

  defp resolve({successes, failures}, queries, limit) do
    merged =
      successes
      |> Enum.map(fn {:ok, results} -> results end)
      |> merge_with_rrf(limit)

    log_summary(queries, successes, failures, length(merged))

    {:ok, merged}
  end

  defp log_summary(queries, successes, failures, returned) do
    Logger.info(
      "Multi-search: #{length(queries)} queries, #{length(successes)} succeeded, " <>
        "#{length(failures)} failed, #{returned} results returned"
    )
  end

  defp per_query_opts(opts, limit) do
    opts
    # Fetch more per-query so RRF has enough candidates to rank
    |> Keyword.put(:limit, limit + 2)
    |> Keyword.delete(:context_limit)
  end

  defp query_outcomes(document_id, queries, search_opts) do
    queries
    |> Task.async_stream(&search_one(document_id, &1, search_opts),
      timeout: :infinity,
      max_concurrency: length(queries)
    )
    |> Enum.map(&outcome/1)
  end

  defp search_one(document_id, query, search_opts) do
    with {:ok, embedding} <- embedding_module().generate(query, []) do
      Search.search_by_embedding(document_id, embedding, search_opts)
    end
  end

  defp outcome({:ok, {:ok, results}}), do: {:ok, results}

  defp outcome({:ok, {:error, reason}}) do
    Logger.warning("Multi-search query failed: #{inspect(reason)}")

    {:error, Errors.normalize(reason)}
  end

  defp outcome({:exit, reason}) do
    # An exit reason can carry a stacktrace holding the query text and its
    # 1024-float embedding, so it stays in the log and never in the returned
    # reason, which the caller renders and stores.
    Logger.warning("Multi-search task exited: #{inspect(reason)}")

    {:error, :task_exited}
  end

  # For each ranked list, assign RRF scores based on position
  # Then sum scores per unique chunk (or fallback page) across all lists
  defp merge_with_rrf(ranked_lists, limit) do
    ranked_lists
    |> Enum.flat_map(&score_list/1)
    |> Enum.group_by(fn {identity, _score, _result} -> identity end)
    |> Enum.map(fn {_identity, entries} -> best_scoring(entries) end)
    |> Enum.sort_by(& &1.rrf_score, :desc)
    |> Enum.take(limit)
  end

  defp score_list(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, rank} ->
      identity = {result.page_id, Map.get(result, :chunk_index)}
      {identity, 1.0 / (@rrf_k + rank), result}
    end)
  end

  defp best_scoring(entries) do
    total_score =
      Enum.reduce(entries, 0.0, fn {_identity, score, _result}, acc -> acc + score end)

    # Keep the result data with the best similarity across queries
    {_identity, _score, best} = Enum.max_by(entries, fn {_, _, result} -> result.similarity end)
    Map.put(best, :rrf_score, total_score)
  end

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end
end
