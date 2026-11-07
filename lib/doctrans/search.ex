defmodule Doctrans.Search do
  @moduledoc """
  Library search: the Pages across every completed Document that answer a
  query, ranked by both what the query means and how it is worded.

  Uses PostgreSQL Full-Text Search for lexical matching with proper stemming
  and ranking, combined with pgvector for semantic similarity; the two
  rankings are fused with Reciprocal Rank Fusion (RRF) in one statement,
  `Doctrans.Search.HybridQuery`. Finding the passages of one Document for a
  question is `Doctrans.Chat.Retrieval`'s, with its own floor and its own
  reading of an embedder that answers without a vector.
  """

  @type hybrid_result :: %{
          page_id: Ecto.UUID.t() | nil,
          document_id: Ecto.UUID.t() | nil,
          document_title: String.t(),
          page_number: pos_integer(),
          image_path: String.t() | nil,
          score: float(),
          snippet: String.t() | nil
        }

  @type search_page :: %{
          results: [hybrid_result()],
          total_count: non_neg_integer(),
          retrieval: :hybrid | :keyword_only
        }

  alias Doctrans.Deps
  alias Doctrans.Repo.Row
  alias Doctrans.Search.HybridQuery

  require Logger

  # RRF constant k - higher values give smoother ranking
  @default_rrf_k 60

  # Minimum cosine similarity a page must reach before the semantic half will
  # rank it at all. Calibrated on the reference library (912 embedded pages,
  # qwen3-embedding truncated to 1024 dimensions) against 12 known-answer and
  # 12 unrelated queries: the best match for a known-answer query scored
  # 0.603-0.772, while the best match an unrelated query could find scored
  # 0.446-0.591. Everything an unrelated query surfaces above 0.50 is
  # content-free boilerplate -- copyright lines, an empty image page -- whose
  # embeddings sit near the corpus centroid and are therefore mildly similar to
  # any query at all.
  #
  # 0.55 is the value that leaves those two bands apart. Raising it to 0.60
  # would empty every unrelated query completely, but it also cuts the single
  # most relevant page for a known-answer query (a section titled
  # "Liquiditatssicherung", 0.597), and dropping a true match to silence
  # boilerplate is the wrong trade for a personal library.
  @semantic_similarity_threshold 0.55

  @default_limit 20

  @doc """
  The smoothing constant of Reciprocal Rank Fusion: a passage at rank `r`
  contributes `1 / (k + r)`, so a higher `k` flattens the difference between
  neighbouring ranks. Library search fuses with it in SQL and
  `Doctrans.Chat.Retrieval` in Elixir; one constant keeps a rank worth the same
  in both.
  """
  @spec rrf_k() :: pos_integer()
  def rrf_k, do: @default_rrf_k

  @doc """
  Performs hybrid search across all pages and counts every match, from one
  query embedding and one statement.

  Results are sorted by RRF score (combination of semantic similarity and
  full-text search ranking).

  The page of results and the total come back from a single SELECT: the count is
  a window over the same filtered rows the page is drawn from. So a query costs
  one inference call, one ranking pass, and leaves no window in which indexing
  can land between a count and a search and move the total.

  The total describes the whole match set rather than the page returned --
  except past the end of it: an `:offset` beyond the last match returns no rows,
  and with no rows there is no window to count, so `:total_count` is 0. A
  caller paginating past the end therefore sees an empty result set, which is
  what it should render anyway.

  `:retrieval` names the ranking that produced the page: `:hybrid` when the
  query was embedded, `:keyword_only` when it could not be and the full-text
  half answered alone. A caller has to be able to tell a degraded search apart
  from a search that found nothing, so this reports the mode rather than
  failing.

  A `:hybrid` search can still be empty. The semantic half only ranks pages that
  clear a cosine similarity floor, so a query about something the library does
  not cover has nothing to fuse and nothing to return -- which is the honest
  answer, and the one an unfiltered ranking of the whole corpus cannot give.

  ## Options

  - `:limit` - Maximum number of results (default: 20)
  - `:offset` - Matches to skip before the first result (default: 0)
  - `:rrf_k` - RRF smoothing constant (default: 60, higher = smoother ranking)

  The semantic similarity floor is not an option: it is calibrated against the
  embedding model rather than chosen per call, and a caller that could lower it
  would be asking for a ranking of the corpus rather than a set of matches.
  """
  @spec search_with_count(String.t() | nil, keyword()) ::
          {:ok, search_page()} | {:error, Doctrans.Errors.reason()}
  def search_with_count(query, opts \\ [])
  def search_with_count("", _opts), do: {:ok, empty_page()}
  def search_with_count(nil, _opts), do: {:ok, empty_page()}

  def search_with_count(query, opts) when is_binary(query) do
    with {:ok, {limit, offset, rrf_k}} <- query_bounds(opts) do
      {embedding, retrieval} = query_embedding(query)

      execute_hybrid_search(query, embedding, retrieval,
        rrf_k: rrf_k,
        min_similarity: @semantic_similarity_threshold,
        limit: limit,
        offset: offset
      )
    end
  end

  # Nothing was asked, so nothing was retrieved -- and no ranking was skipped,
  # which is why the mode is the healthy one rather than a degraded one.
  defp empty_page, do: %{results: [], total_count: 0, retrieval: :hybrid}

  # The threshold does not vary by retrieval mode. It governs which pages the
  # semantic half is allowed to rank, and in keyword-only mode that half is
  # already empty -- a NULL vector clears no floor at all. Its predecessor, a
  # floor on the *fused* score, did have to vary: a fused score is a function of
  # rank, so a single-ranking keyword-only search crossed it at rank 41 and lost
  # every deeper match along with the count that agreed with them. Filtering
  # where relevance is actually measurable rather than where it has already been
  # flattened into a rank is what lets one number serve both modes.

  # An embedding server outage must not read as "nothing matched": rank on the
  # full-text half alone rather than failing a search the keyword index can
  # still answer, and hand back the mode so the caller can say which it got.
  # `{:ok, nil}` is a legal embedding result (`EmbeddingBehaviour`) and is the
  # same situation -- reporting `:hybrid` for it would claim a ranking that did
  # not run. Either way `nil` reaches the statement as a NULL vector, which
  # `HybridQuery.run/3` turns into an empty semantic ranking.
  defp query_embedding(query) do
    case Deps.embedding().generate(query, []) do
      {:ok, nil} ->
        Logger.warning("Search embedding returned no vector, keyword-only")
        {nil, :keyword_only}

      {:ok, embedding} ->
        {embedding, :hybrid}

      {:error, reason} ->
        Logger.warning(
          "Search embedding failed, keyword-only: #{inspect(reason, limit: 5, printable_limit: 256)}"
        )

        {nil, :keyword_only}
    end
  end

  # Postgres takes LIMIT/OFFSET as bigint and the RRF constant as int4. Handing
  # Postgrex a value outside those ranges -- an unclamped `?page=` reaching
  # `:offset`, say -- makes it *raise* rather than return an error, which would
  # escape the `{:ok, _} | {:error, _}` contract above and take the calling
  # process down with it. Reject out-of-range bounds here so the contract holds
  # for every caller, however it was reached.
  @max_bigint 9_223_372_036_854_775_807
  @max_int4 2_147_483_647

  defp query_bounds(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)
    rrf_k = Keyword.get(opts, :rrf_k, @default_rrf_k)

    cond do
      not bounded?(limit, @max_bigint) -> {:error, {:invalid_search_bounds, [limit: limit]}}
      not bounded?(offset, @max_bigint) -> {:error, {:invalid_search_bounds, [offset: offset]}}
      not bounded?(rrf_k, @max_int4) -> {:error, {:invalid_search_bounds, [rrf_k: rrf_k]}}
      true -> {:ok, {limit, offset, rrf_k}}
    end
  end

  defp bounded?(value, max), do: is_integer(value) and value >= 0 and value <= max

  defp execute_hybrid_search(query, query_embedding, retrieval, query_opts) do
    with {:ok, %{rows: rows, columns: columns}} <-
           HybridQuery.run(query, query_embedding, query_opts) do
      rows = Enum.map(rows, &Row.to_map(&1, columns))

      {:ok,
       %{
         results: Enum.map(rows, &format_row/1),
         total_count: total_count(rows),
         retrieval: retrieval
       }}
    end
  end

  # Every row carries the same window total, so the first one answers for all of
  # them. No rows means this page of the match set is empty and the window has
  # nothing to report -- see `search_with_count/2` on paginating past the end.
  defp total_count([]), do: 0
  defp total_count([row | _rest]), do: Map.fetch!(row, "total_count")

  defp format_row(result) do
    %{
      page_id: Row.uuid_to_string(result["page_id"]),
      document_id: Row.uuid_to_string(result["document_id"]),
      document_title: result["document_title"],
      page_number: result["page_number"],
      image_path: result["image_path"],
      score: Row.to_float(result["rrf_score"]),
      snippet: format_snippet(result["snippet"])
    }
  end

  # Format snippet: normalize whitespace, strip HTML bold tags from ts_headline
  defp format_snippet(nil), do: nil

  defp format_snippet(text) do
    text
    |> String.replace(~r/<b>|<\/b>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
