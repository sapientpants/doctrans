defmodule Doctrans.Search do
  @moduledoc """
  Hybrid search combining semantic similarity and full-text search.

  Uses PostgreSQL Full-Text Search for lexical matching with proper
  stemming and ranking, combined with pgvector for semantic similarity.
  Results are combined using Reciprocal Rank Fusion (RRF).
  """

  alias Doctrans.Repo

  # Allow embedding module to be configured for testing
  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end

  @doc """
  Performs hybrid search across all pages.

  Returns a list of search results sorted by RRF score (combination of
  semantic similarity and full-text search ranking).

  ## Options

  - `:limit` - Maximum number of results (default: 20)
  - `:rrf_k` - RRF smoothing constant (default: 60, higher = smoother ranking)
  """
  def search(query, opts \\ [])
  def search("", _opts), do: {:ok, []}
  def search(nil, _opts), do: {:ok, []}

  # RRF constant k - higher values give smoother ranking
  @default_rrf_k 60

  # Minimum RRF score threshold to filter out irrelevant results
  # With k=60, a single match at rank 1 gives score ~0.016
  @min_score_threshold 0.01

  def search(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    rrf_k = Keyword.get(opts, :rrf_k, @default_rrf_k)

    with {:ok, query_embedding} <- embedding_module().generate(query, []) do
      results = execute_hybrid_search(query, query_embedding, rrf_k, limit)

      {:ok, results}
    end
  end

  defp execute_hybrid_search(query, query_embedding, rrf_k, limit) do
    # Use CTE-based query for efficient RRF calculation
    # - semantic_ranked: pages ranked by embedding similarity
    # - fts_ranked: pages ranked by full-text search score
    # - combined: FULL OUTER JOIN with RRF score calculation
    sql = """
    WITH semantic_ranked AS (
      SELECT
        p.id,
        p.document_id,
        d.title as document_title,
        p.page_number,
        p.image_path,
        p.original_markdown,
        p.translated_markdown,
        1 - (p.embedding <=> $1::vector) as semantic_score,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> $1::vector ASC) as semantic_rank
      FROM pages p
      JOIN documents d ON p.document_id = d.id
      WHERE d.status = 'completed'
        AND p.extraction_status = 'completed'
        AND p.embedding IS NOT NULL
      ORDER BY p.embedding <=> $1::vector ASC
      LIMIT $4
    ),
    fts_ranked AS (
      SELECT
        p.id,
        p.document_id,
        d.title as document_title,
        p.page_number,
        p.image_path,
        p.original_markdown,
        p.translated_markdown,
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
      ORDER BY fts_score DESC
      LIMIT $4
    ),
    combined AS (
      SELECT
        COALESCE(s.id, f.id) as page_id,
        COALESCE(s.document_id, f.document_id) as document_id,
        COALESCE(s.document_title, f.document_title) as document_title,
        COALESCE(s.page_number, f.page_number) as page_number,
        COALESCE(s.image_path, f.image_path) as image_path,
        COALESCE(s.translated_markdown, s.original_markdown, f.translated_markdown, f.original_markdown) as snippet_source,
        COALESCE(s.semantic_score, 0) as semantic_score,
        COALESCE(f.fts_score, 0) as fts_score,
        s.semantic_rank,
        f.fts_rank,
        -- RRF score: sum of reciprocal ranks
        COALESCE(1.0 / ($3 + s.semantic_rank), 0) +
        COALESCE(1.0 / ($3 + f.fts_rank), 0) as rrf_score
      FROM semantic_ranked s
      FULL OUTER JOIN fts_ranked f ON s.id = f.id
    )
    SELECT
      page_id,
      document_id,
      document_title,
      page_number,
      image_path,
      snippet_source,
      rrf_score
    FROM combined
    WHERE rrf_score >= $6
    ORDER BY rrf_score DESC
    LIMIT $5
    """

    case Repo.query(sql, [query_embedding, query, rrf_k, limit * 5, limit, @min_score_threshold]) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, &format_row(&1, columns))

      {:error, error} ->
        require Logger
        Logger.error("Hybrid search query failed: #{inspect(error)}")
        []
    end
  end

  defp format_row(row, columns) do
    result = Enum.zip(columns, row) |> Map.new()

    %{
      page_id: uuid_to_string(result["page_id"]),
      document_id: uuid_to_string(result["document_id"]),
      document_title: result["document_title"],
      page_number: result["page_number"],
      image_path: result["image_path"],
      score: to_float(result["rrf_score"]),
      snippet: extract_snippet(result["snippet_source"], 200)
    }
  end

  defp uuid_to_string(<<_::128>> = binary), do: Ecto.UUID.load!(binary)
  defp uuid_to_string(string) when is_binary(string), do: string
  defp uuid_to_string(nil), do: nil

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i / 1

  defp extract_snippet(nil, _), do: nil

  defp extract_snippet(text, max_length) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_length)
    |> then(fn s -> if String.length(s) >= max_length, do: s <> "...", else: s end)
  end
end
