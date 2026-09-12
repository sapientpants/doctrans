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
  @spec search_with_queries(Ecto.UUID.t(), [String.t()], keyword()) ::
          {:ok, [Search.document_result()]}
  def search_with_queries(document_id, queries, opts \\ [])

  def search_with_queries(_document_id, [], _opts), do: {:ok, []}

  def search_with_queries(document_id, queries, opts) when is_list(queries) do
    limit = Keyword.get(opts, :limit, 3)
    ranked_lists = ranked_lists(document_id, queries, per_query_opts(opts, limit))
    merged = merge_with_rrf(ranked_lists, limit)

    Logger.info(
      "Multi-search: #{length(queries)} queries, #{length(ranked_lists)} successful, #{length(merged)} results returned"
    )

    {:ok, merged}
  end

  defp per_query_opts(opts, limit) do
    opts
    # Fetch more per-query so RRF has enough candidates to rank
    |> Keyword.put(:limit, limit + 2)
    |> Keyword.delete(:context_limit)
  end

  defp ranked_lists(document_id, queries, search_opts) do
    queries
    |> Task.async_stream(&search_one(document_id, &1, search_opts),
      timeout: :infinity,
      max_concurrency: length(queries)
    )
    |> Enum.flat_map(&collect_results/1)
  end

  defp search_one(document_id, query, search_opts) do
    with {:ok, embedding} <- embedding_module().generate(query, []) do
      Search.search_by_embedding(document_id, embedding, search_opts)
    end
  end

  defp collect_results({:ok, {:ok, results}}), do: [results]

  defp collect_results({:ok, {:error, reason}}) do
    Logger.warning("Multi-search query failed: #{inspect(reason)}")
    []
  end

  defp collect_results({:exit, reason}) do
    Logger.warning("Multi-search task exited: #{inspect(reason)}")
    []
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
