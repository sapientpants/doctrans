defmodule Doctrans.Chat.MultiSearch do
  @moduledoc """
  Searches a document with multiple query variants and merges results via
  Reciprocal Rank Fusion (RRF).

  Each query is embedded and searched independently in parallel. Results are
  deduplicated by page and chunk index and scored using RRF to surface results that rank highly
  across multiple query phrasings.
  """

  alias Doctrans.Search

  require Logger

  @rrf_k 60

  @doc """
  Searches a document using multiple query strings and returns merged results.

  Generates embeddings for all queries in parallel, runs pgvector searches,
  and merges results using Reciprocal Rank Fusion.

  ## Options

  - `:limit` - Maximum number of results to return (default: 3)
  - `:min_similarity` - Minimum cosine similarity threshold (default: Search default)
  """
  def search_with_queries(document_id, queries, opts \\ [])

  def search_with_queries(_document_id, [], _opts), do: {:ok, []}

  def search_with_queries(document_id, queries, opts) when is_list(queries) do
    limit = Keyword.get(opts, :limit, 3)
    # Fetch more per-query so RRF has enough candidates to rank
    per_query_limit = limit + 2

    search_opts =
      opts
      |> Keyword.put(:limit, per_query_limit)
      |> Keyword.delete(:context_limit)

    ranked_lists =
      queries
      |> Task.async_stream(
        fn query ->
          with {:ok, embedding} <- embedding_module().generate(query, []) do
            Search.search_by_embedding(document_id, embedding, search_opts)
          end
        end,
        timeout: :infinity,
        max_concurrency: length(queries)
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, results}} ->
          [results]

        {:ok, {:error, reason}} ->
          Logger.warning("Multi-search query failed: #{inspect(reason)}")
          []

        {:exit, reason} ->
          Logger.warning("Multi-search task exited: #{inspect(reason)}")
          []
      end)

    merged = merge_with_rrf(ranked_lists, limit)

    Logger.info(
      "Multi-search: #{length(queries)} queries, #{length(ranked_lists)} successful, #{length(merged)} results returned"
    )

    {:ok, merged}
  end

  defp merge_with_rrf(ranked_lists, limit) do
    # For each ranked list, assign RRF scores based on position
    # Then sum scores per unique chunk (or fallback page) across all lists
    ranked_lists
    |> Enum.flat_map(fn results ->
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, rank} ->
        identity = {result.page_id, Map.get(result, :chunk_index)}
        {identity, 1.0 / (@rrf_k + rank), result}
      end)
    end)
    |> Enum.group_by(fn {identity, _score, _result} -> identity end)
    |> Enum.map(fn {_identity, entries} ->
      total_score = Enum.reduce(entries, 0.0, fn {_, score, _}, acc -> acc + score end)
      # Keep the result data with the best similarity across queries
      {_, _, best_result} = Enum.max_by(entries, fn {_, _, result} -> result.similarity end)
      Map.put(best_result, :rrf_score, total_score)
    end)
    |> Enum.sort_by(& &1.rrf_score, :desc)
    |> Enum.take(limit)
  end

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end
end
