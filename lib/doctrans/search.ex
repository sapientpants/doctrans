defmodule Doctrans.Search do
  @moduledoc """
  Hybrid search combining semantic similarity and full-text search.

  Uses PostgreSQL Full-Text Search for lexical matching with proper
  stemming and ranking, combined with pgvector for semantic similarity.
  Results are combined using Reciprocal Rank Fusion (RRF).
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

  @type document_result :: %{
          :page_id => Ecto.UUID.t() | nil,
          :page_number => pos_integer(),
          :original_markdown => String.t() | nil,
          :translated_markdown => String.t() | nil,
          :similarity => float(),
          :content_revision => integer() | nil,
          optional(:chunk_id) => Ecto.UUID.t() | nil,
          optional(:chunk_index) => non_neg_integer(),
          # Present only on results fused by `Doctrans.Chat.Retrieval`.
          optional(:rrf_score) => float()
        }

  alias Doctrans.Deps
  alias Doctrans.Repo
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

  # Minimum cosine similarity threshold for chat context
  # Pages below this threshold are considered irrelevant
  # Cosine similarity: 0 = unrelated, 1 = identical
  # 0.30 keeps recall high for abstract/analytical queries (e.g. "assess the
  # balance sheet") while still filtering clear noise
  @chat_similarity_threshold 0.30

  @doc """
  Performs semantic search within a specific document.

  Returns pages from the given document sorted by semantic similarity to the query.
  This is optimized for RAG use cases where we need to find relevant context
  from a single document.

  Only pages with similarity above the threshold (#{@chat_similarity_threshold}) are returned
  to ensure only highly relevant content is used for chat responses.

  ## Options

  - `:limit` - Maximum number of pages to return (default: 3)
  - `:min_similarity` - Minimum similarity threshold (default: #{@chat_similarity_threshold})

  ## Returns

  `{:ok, results}`, a list of `t:document_result/0` in descending similarity.
  Results are chunk-first: when the document has embedded chunks, each result
  is one chunk, its `:original_markdown` is the chunk's text, `:chunk_id` and
  `:chunk_index` are set, and `:translated_markdown` is always `nil` -- chunks
  carry no translation. Only when no chunk clears the floor does the search
  fall back to whole pages, whose results carry the page's text in both fields
  (`:translated_markdown` `nil` until the page is translated) and no chunk
  keys. `Doctrans.Chat` reads the fields on that contract: the chunk keys say
  which text to quote and whether a translated copy may outrank it.

  `{:error, :embedding_unavailable}` when the embedder succeeds without a
  vector: nothing can be ranked against it, and `{:ok, []}` would report a
  search that never ran as "nothing matched" -- the same reading
  `Doctrans.Chat.Retrieval` and library search give that result. Any other
  embedder or database error is passed through.
  """
  @spec search_in_document(Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, [document_result()]} | {:error, Doctrans.Errors.reason()}
  def search_in_document(document_id, query, opts \\ [])
  def search_in_document(_document_id, "", _opts), do: {:ok, []}
  def search_in_document(_document_id, nil, _opts), do: {:ok, []}

  def search_in_document(document_id, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 3)
    min_similarity = Keyword.get(opts, :min_similarity, @chat_similarity_threshold)

    case Deps.embedding().generate(query, []) do
      {:ok, nil} ->
        {:error, :embedding_unavailable}

      {:ok, query_embedding} ->
        search_by_embedding(document_id, query_embedding,
          limit: limit,
          min_similarity: min_similarity
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Performs semantic search within a document using a pre-computed embedding vector.

  This is useful when you already have an embedding and want to avoid recomputing it,
  for example when searching with multiple query variants in parallel.

  ## Options

  - `:limit` - Maximum number of pages to return (default: 3)
  - `:min_similarity` - Minimum similarity threshold (default: #{@chat_similarity_threshold})
  """
  @spec search_by_embedding(Ecto.UUID.t(), Pgvector.t() | nil, keyword()) ::
          {:ok, [document_result()]} | {:error, Doctrans.Errors.reason()}
  def search_by_embedding(document_id, query_embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)
    min_similarity = Keyword.get(opts, :min_similarity, @chat_similarity_threshold)

    # Try chunk-level search first, fall back to page-level if no chunks exist
    case execute_chunk_search(document_id, query_embedding, limit, min_similarity) do
      {:ok, []} -> execute_page_search(document_id, query_embedding, limit, min_similarity)
      result -> result
    end
  end

  # Retrieval within one document is exact, by construction of the SQL.
  #
  # The HNSW indexes on `chunks.embedding` and `pages.embedding` answer
  # `ORDER BY embedding <=> query` approximately: the scan collects
  # `hnsw.ef_search` candidates (40 by default) from the whole index and Postgres
  # applies the WHERE clause to those afterwards (pgvector, "Filtering"). The
  # candidates are the rows nearest the query across every document, plus the
  # index entries of rows that have since been deleted or rolled back and not yet
  # vacuumed, so when enough of them outrank this document's rows the row we want
  # falls outside the set and the query comes back short -- no error, just a
  # missing match. Whether the planner takes that path depends on its statistics
  # at the time, which is why the miss only showed up intermittently (#184).
  #
  # A document's own rows are few and reachable through the `document_id` btree,
  # so these queries collect them, with their distances, in a MATERIALIZED CTE
  # that has no ORDER BY the approximate index could serve, and rank them
  # afterwards. The library-wide search in `HybridQuery` ranks its semantic half
  # the same way, and for the same reason (#218).
  #
  # Static heredoc; every value reaches Postgres as a bound parameter ($1..$4) via
  # `run_document_search/6`, which owns the `Repo.query/2` call and its skip.
  defp execute_chunk_search(document_id, query_embedding, limit, min_similarity) do
    sql = """
    WITH candidates AS MATERIALIZED (
      SELECT
        c.id as chunk_id,
        c.page_id,
        p.page_number,
        c.content as original_markdown,
        c.chunk_index,
        p.content_revision,
        c.embedding <=> $1::vector as distance
      FROM chunks c
      JOIN pages p ON c.page_id = p.id
      WHERE p.document_id = $2
        AND p.extraction_status = 'completed'
        AND c.embedding IS NOT NULL
    )
    SELECT
      chunk_id,
      page_id,
      page_number,
      original_markdown,
      NULL::text as translated_markdown,
      chunk_index,
      content_revision,
      1 - distance as similarity
    FROM candidates
    WHERE 1 - distance >= $4
    ORDER BY distance ASC
    LIMIT $3
    """

    run_document_search("Chunk", sql, document_id, query_embedding, limit, min_similarity)
  end

  # Exact for the same reason as `execute_chunk_search/4`; see the note there.
  #
  # Static heredoc; $1..$4 are bound parameters, nothing is interpolated into the SQL.
  defp execute_page_search(document_id, query_embedding, limit, min_similarity) do
    sql = """
    WITH candidates AS MATERIALIZED (
      SELECT
        p.id as page_id,
        p.page_number,
        p.original_markdown,
        p.translated_markdown,
        p.content_revision,
        p.embedding <=> $1::vector as distance
      FROM pages p
      WHERE p.document_id = $2
        AND p.extraction_status = 'completed'
        AND p.embedding IS NOT NULL
    )
    SELECT
      page_id,
      page_number,
      original_markdown,
      translated_markdown,
      content_revision,
      1 - distance as similarity
    FROM candidates
    WHERE 1 - distance >= $4
    ORDER BY distance ASC
    LIMIT $3
    """

    run_document_search("Page", sql, document_id, query_embedding, limit, min_similarity)
  end

  # Both in-document statements bind the same four parameters in the same
  # order and fail the same way; what differs is the SQL and the row shape,
  # and the row's own columns say which shape it is.
  #
  # `sql` is one of the two static heredocs above, never built from input, and
  # every value reaches Postgres as a bound parameter. Flagged only because the
  # statement arrives in a variable.
  # sobelow_skip ["SQL.Query"]
  defp run_document_search(label, sql, document_id, query_embedding, limit, min_similarity) do
    params = [query_embedding, Ecto.UUID.dump!(document_id), limit, min_similarity]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, &format_document_row(row_to_map(&1, columns)))}

      {:error, error} ->
        Logger.error(
          "#{label} search query failed: #{inspect(error, limit: 5, printable_limit: 256)}"
        )

        {:error, {:database_error, [reason: error]}}
    end
  end

  # Only the chunk statement selects `chunk_id` and `chunk_index`; a page row
  # carries neither key, which is what `t:document_result/0` promises.
  defp format_document_row(result) do
    base = %{
      page_id: uuid_to_string(result["page_id"]),
      page_number: result["page_number"],
      original_markdown: result["original_markdown"],
      translated_markdown: result["translated_markdown"],
      content_revision: result["content_revision"],
      similarity: to_float(result["similarity"])
    }

    case result do
      %{"chunk_id" => chunk_id, "chunk_index" => chunk_index} ->
        Map.merge(base, %{chunk_id: uuid_to_string(chunk_id), chunk_index: chunk_index})

      _page_row ->
        base
    end
  end

  defp execute_hybrid_search(query, query_embedding, retrieval, query_opts) do
    with {:ok, %{rows: rows, columns: columns}} <-
           HybridQuery.run(query, query_embedding, query_opts) do
      rows = Enum.map(rows, &row_to_map(&1, columns))

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

  # A Postgrex row keyed by its column names.
  defp row_to_map(row, columns), do: columns |> Enum.zip(row) |> Map.new()

  defp format_row(result) do
    %{
      page_id: uuid_to_string(result["page_id"]),
      document_id: uuid_to_string(result["document_id"]),
      document_title: result["document_title"],
      page_number: result["page_number"],
      image_path: result["image_path"],
      score: to_float(result["rrf_score"]),
      snippet: format_snippet(result["snippet"])
    }
  end

  defp uuid_to_string(<<_::128>> = binary) do
    case Ecto.UUID.load(binary) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_to_string(string) when is_binary(string), do: string
  defp uuid_to_string(nil), do: nil

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i / 1

  # Format snippet: normalize whitespace, strip HTML bold tags from ts_headline
  defp format_snippet(nil), do: nil

  defp format_snippet(text) do
    text
    |> String.replace(~r/<b>|<\/b>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
