defmodule Doctrans.Search.HybridQuery do
  @moduledoc """
  The one statement behind global search.

  A single SELECT fuses a semantic ranking and a full-text ranking with
  Reciprocal Rank Fusion, draws a page out of the fused set, and totals that
  whole set with a window in the same pass -- so the count and the page it
  ships with cannot disagree about what matched.

  It serves both retrieval modes. Given `nil` for the embedding the semantic
  CTE selects nothing, and a query that could not be embedded still ranks on
  the full-text half instead of failing outright; see
  `Doctrans.Search.search_with_count/2`.

  Rows come back exactly as Postgrex returns them: `Doctrans.Search` owns what
  a search result looks like, this module owns how one is found.
  """

  alias Doctrans.Repo

  require Logger

  @doc """
  Runs the statement, returning Postgrex's result or a tagged database error.

  The knobs arrive as options because `:limit` and `:offset` are adjacent,
  identically typed, and silently transposable positionally:

  - `:rrf_k` - smooths the fusion
  - `:min_similarity` - the cosine floor the semantic half must clear
  - `:limit` / `:offset` - the page to draw

  All four are the caller's values rather than this module's defaults, so every
  search knob stays documented in one place.
  """
  @spec run(String.t(), Pgvector.t() | nil, keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, Doctrans.Errors.reason()}
  # Static heredoc; $1..$6 are bound parameters, including the user's search text ($2)
  # and the pagination values ($5, $6). No interpolation anywhere in the statement.
  # sobelow_skip ["SQL.Query"]
  def run(query, query_embedding, opts) do
    # Use CTE-based query for efficient RRF calculation
    # - semantic_ranked: pages ranked by embedding similarity (IDs and ranks only),
    #   empty when $1 is NULL so an unembeddable query still gets the fts half
    #   rather than an error -- one statement, both retrieval modes. $4 is the
    #   similarity floor: without it this CTE ranks every embedded page in the
    #   library, so the deepest ranks are whatever the corpus happens to hold
    #   rather than anything the query asked for.
    # - fts_ranked: pages ranked by full-text search score (IDs and ranks only)
    # - combined: FULL OUTER JOIN with RRF score calculation
    # - Final SELECT joins back to pages for snippets using ts_headline(), and
    #   totals the filtered set with a window so the count cannot disagree with
    #   the page about what matched
    sql = """
    WITH semantic_ranked AS (
      SELECT
        p.id,
        p.document_id,
        1 - (p.embedding <=> $1::vector) as semantic_score,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> $1::vector ASC) as semantic_rank
      FROM pages p
      JOIN documents d ON p.document_id = d.id
      WHERE $1::vector IS NOT NULL
        AND d.status = 'completed'
        AND p.extraction_status = 'completed'
        AND p.embedding IS NOT NULL
        AND (1 - (p.embedding <=> $1::vector)) >= $4
    ),
    fts_ranked AS (
      SELECT
        p.id,
        p.document_id,
        d.target_language,
        (
          COALESCE(ts_rank_cd(p.original_searchable, plainto_tsquery('simple', $2)), 0) +
          COALESCE(ts_rank_cd(p.translated_searchable, plainto_tsquery(get_fts_config(d.target_language), $2)), 0)
        ) as fts_score,
        ROW_NUMBER() OVER (
          ORDER BY (
            COALESCE(ts_rank_cd(p.original_searchable, plainto_tsquery('simple', $2)), 0) +
            COALESCE(ts_rank_cd(p.translated_searchable, plainto_tsquery(get_fts_config(d.target_language), $2)), 0)
          ) DESC
        ) as fts_rank
      FROM pages p
      JOIN documents d ON p.document_id = d.id
      WHERE d.status = 'completed'
        AND p.extraction_status = 'completed'
        AND (
          p.original_searchable @@ plainto_tsquery('simple', $2)
          OR p.translated_searchable @@ plainto_tsquery(get_fts_config(d.target_language), $2)
        )
    ),
    combined AS (
      SELECT
        COALESCE(s.id, f.id) as page_id,
        COALESCE(s.document_id, f.document_id) as document_id,
        COALESCE(s.semantic_score, 0) as semantic_score,
        COALESCE(f.fts_score, 0) as fts_score,
        f.target_language,
        s.semantic_rank,
        f.fts_rank,
        -- RRF score: sum of reciprocal ranks
        COALESCE(1.0 / ($3 + s.semantic_rank), 0) +
        COALESCE(1.0 / ($3 + f.fts_rank), 0) as rrf_score
      FROM semantic_ranked s
      FULL OUTER JOIN fts_ranked f ON s.id = f.id
    )
    SELECT
      c.page_id,
      c.document_id,
      d.title as document_title,
      p.page_number,
      p.image_path,
      c.rrf_score,
      -- Evaluated after WHERE and before LIMIT/OFFSET, so this totals every
      -- match, not the rows this page returns. Same rows, same predicates, one
      -- snapshot: the total and the results cannot drift apart.
      COUNT(*) OVER () as total_count,
      -- Use ts_headline for FTS matches (shows context around match)
      -- Fall back to substring for semantic-only matches
      CASE
        WHEN c.fts_score > 0 AND p.translated_markdown IS NOT NULL THEN
          ts_headline(
            get_fts_config(COALESCE(c.target_language, 'en')),
            p.translated_markdown,
            plainto_tsquery(get_fts_config(COALESCE(c.target_language, 'en')), $2),
            'MaxWords=35, MinWords=15, MaxFragments=1'
          )
        WHEN c.fts_score > 0 AND p.original_markdown IS NOT NULL THEN
          ts_headline(
            'simple',
            p.original_markdown,
            plainto_tsquery('simple', $2),
            'MaxWords=35, MinWords=15, MaxFragments=1'
          )
        WHEN p.translated_markdown IS NOT NULL THEN
          CASE
            WHEN LENGTH(p.translated_markdown) > 200 THEN LEFT(p.translated_markdown, 200) || '...'
            ELSE p.translated_markdown
          END
        ELSE
          CASE
            WHEN LENGTH(p.original_markdown) > 200 THEN LEFT(p.original_markdown, 200) || '...'
            ELSE p.original_markdown
          END
      END as snippet
    FROM combined c
    JOIN pages p ON c.page_id = p.id
    JOIN documents d ON c.document_id = d.id
    -- No floor on the fused score. A fused score is a function of rank, not of
    -- relevance: a row that is the only match in the library and a row 500
    -- matches deep are told apart by 1/(k + rank) alone, so any floor here is a
    -- cap on how many matches the library is allowed to have. The 0.01 floor
    -- this replaces cut off at rank 41 for the default k=60 and shrank the
    -- COUNT(*) OVER () total to agree with itself. Relevance is now decided
    -- where it can be: the semantic half clears $4, the full-text half clears
    -- its tsquery, and every row reaching here earned its place.
    -- page_id breaks RRF ties deterministically. Without it Postgres may order
    -- tied rows differently per statement, which paginates one row onto two
    -- pages and drops another entirely.
    ORDER BY c.rrf_score DESC, c.page_id
    LIMIT $5
    OFFSET $6
    """

    params = [
      query_embedding,
      query,
      Keyword.fetch!(opts, :rrf_k),
      Keyword.fetch!(opts, :min_similarity),
      Keyword.fetch!(opts, :limit),
      Keyword.fetch!(opts, :offset)
    ]

    case Repo.query(sql, params) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        # A %Postgrex.Error{} carries the statement that failed -- this whole
        # heredoc -- so the log gets it bounded rather than several KB at a time.
        Logger.error(
          "Hybrid search query failed: #{inspect(error, limit: 5, printable_limit: 256)}"
        )

        {:error, {:database_error, [reason: error]}}
    end
  end
end
