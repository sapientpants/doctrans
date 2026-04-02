defmodule Doctrans.Chat.MultiSearch do
  @moduledoc """
  Searches a document with multiple query variants and merges results via
  Reciprocal Rank Fusion (RRF).

  Each query is embedded and searched independently in parallel. Results are
  deduplicated by page and scored using RRF to surface pages that rank highly
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

  - `:limit` - Maximum number of pages to return (default: 3)
  - `:min_similarity` - Minimum cosine similarity threshold (default: Search default)
  """
  def search_with_queries(document_id, queries, opts \\ []) do
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
        {:ok, {:ok, pages}} ->
          [pages]

        {:ok, {:error, reason}} ->
          Logger.warning("Multi-search query failed: #{inspect(reason)}")
          []

        {:exit, reason} ->
          Logger.warning("Multi-search task exited: #{inspect(reason)}")
          []
      end)

    merged = merge_with_rrf(ranked_lists, limit)

    Logger.info(
      "Multi-search: #{length(queries)} queries, #{length(ranked_lists)} successful, #{length(merged)} pages returned"
    )

    {:ok, merged}
  end

  defp merge_with_rrf(ranked_lists, limit) do
    # For each ranked list, assign RRF scores based on position
    # Then sum scores per unique page across all lists
    ranked_lists
    |> Enum.flat_map(fn pages ->
      pages
      |> Enum.with_index(1)
      |> Enum.map(fn {page, rank} ->
        {page.page_id, 1.0 / (@rrf_k + rank), page}
      end)
    end)
    |> Enum.group_by(fn {page_id, _score, _page} -> page_id end)
    |> Enum.map(fn {_page_id, entries} ->
      total_score = Enum.reduce(entries, 0.0, fn {_, score, _}, acc -> acc + score end)
      # Use the page data from the highest-scoring entry (best similarity)
      {_, _, best_page} = Enum.max_by(entries, fn {_, _, page} -> page.similarity end)
      Map.put(best_page, :rrf_score, total_score)
    end)
    |> Enum.sort_by(& &1.rrf_score, :desc)
    |> Enum.take(limit)
  end

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end
end
