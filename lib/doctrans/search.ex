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
  # With k=60, a single match at rank 1 gives score ~0.0164 (1/61)
  @min_score_threshold 0.01

  def search(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    rrf_k = Keyword.get(opts, :rrf_k, @default_rrf_k)

    with {:ok, query_embedding} <- embedding_module().generate(query, []) do
      execute_hybrid_search(query, query_embedding, rrf_k, limit, offset)
    end
  end

  # Minimum cosine similarity threshold for chat context
  # Pages below this threshold are considered irrelevant
  # Cosine similarity: 0 = unrelated, 1 = identical
  # 0.35 is a reasonable threshold to filter out noise while keeping relevant content
  @chat_similarity_threshold 0.35

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

  A list of maps containing:
  - `:page_id` - The page's UUID
  - `:page_number` - Page number in the document
  - `:original_markdown` - Original extracted text
  - `:translated_markdown` - Translated text (if available)
  - `:similarity` - Cosine similarity score (0-1, higher is better)
  """
  def search_in_document(document_id, query, opts \\ [])
  def search_in_document(_document_id, "", _opts), do: {:ok, []}
  def search_in_document(_document_id, nil, _opts), do: {:ok, []}

  def search_in_document(document_id, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 3)
    min_similarity = Keyword.get(opts, :min_similarity, @chat_similarity_threshold)

    with {:ok, query_embedding} <- embedding_module().generate(query, []) do
      execute_document_search(document_id, query_embedding, limit, min_similarity)
    end
  end

  defp execute_document_search(document_id, query_embedding, limit, min_similarity) do
    # Filter by similarity threshold in the query to only return highly relevant pages
    sql = """
    SELECT
      p.id as page_id,
      p.page_number,
      p.original_markdown,
      p.translated_markdown,
      1 - (p.embedding <=> $1::vector) as similarity
    FROM pages p
    WHERE p.document_id = $2
      AND p.extraction_status = 'completed'
      AND p.embedding IS NOT NULL
      AND (1 - (p.embedding <=> $1::vector)) >= $4
    ORDER BY p.embedding <=> $1::vector ASC
    LIMIT $3
    """

    case Repo.query(sql, [query_embedding, Ecto.UUID.dump!(document_id), limit, min_similarity]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, &format_document_search_row(&1, columns))}

      {:error, error} ->
        require Logger
        Logger.error("Document search query failed: #{inspect(error)}")
        {:error, {:database_error, error}}
    end
  end

  defp format_document_search_row(row, columns) do
    result = Enum.zip(columns, row) |> Map.new()

    %{
      page_id: uuid_to_string(result["page_id"]),
      page_number: result["page_number"],
      original_markdown: result["original_markdown"],
      translated_markdown: result["translated_markdown"],
      similarity: to_float(result["similarity"])
    }
  end

  @doc """
  Counts total matching results for a query.

  Used for pagination to determine total pages.

  ## Options

  - `:rrf_k` - RRF smoothing constant (default: 60)
  """
  def count_results(query, opts \\ [])
  def count_results("", _opts), do: {:ok, 0}
  def count_results(nil, _opts), do: {:ok, 0}

  def count_results(query, opts) when is_binary(query) do
    rrf_k = Keyword.get(opts, :rrf_k, @default_rrf_k)

    with {:ok, query_embedding} <- embedding_module().generate(query, []) do
      execute_count_query(query, query_embedding, rrf_k)
    end
  end

  defp execute_count_query(query, query_embedding, rrf_k) do
    sql = """
    WITH semantic_ranked AS (
      SELECT
        p.id,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> $1::vector ASC) as semantic_rank
      FROM pages p
      JOIN documents d ON p.document_id = d.id
      WHERE d.status = 'completed'
        AND p.extraction_status = 'completed'
        AND p.embedding IS NOT NULL
    ),
    fts_ranked AS (
      SELECT
        p.id,
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
        COALESCE(1.0 / ($3 + s.semantic_rank), 0) +
        COALESCE(1.0 / ($3 + f.fts_rank), 0) as rrf_score
      FROM semantic_ranked s
      FULL OUTER JOIN fts_ranked f ON s.id = f.id
    )
    SELECT COUNT(*) as total
    FROM combined
    WHERE rrf_score >= $4
    """

    case Repo.query(sql, [query_embedding, query, rrf_k, @min_score_threshold]) do
      {:ok, %{rows: [[count]]}} ->
        {:ok, count}

      {:error, error} ->
        require Logger
        Logger.error("Count query failed: #{inspect(error)}")
        {:error, {:database_error, error}}
    end
  end

  defp execute_hybrid_search(query, query_embedding, rrf_k, limit, offset) do
    # Use CTE-based query for efficient RRF calculation
    # - semantic_ranked: pages ranked by embedding similarity (IDs and ranks only)
    # - fts_ranked: pages ranked by full-text search score (IDs and ranks only)
    # - combined: FULL OUTER JOIN with RRF score calculation
    # - Final SELECT joins back to pages for snippets using ts_headline()
    sql = """
    WITH semantic_ranked AS (
      SELECT
        p.id,
        p.document_id,
        1 - (p.embedding <=> $1::vector) as semantic_score,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> $1::vector ASC) as semantic_rank
      FROM pages p
      JOIN documents d ON p.document_id = d.id
      WHERE d.status = 'completed'
        AND p.extraction_status = 'completed'
        AND p.embedding IS NOT NULL
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
    WHERE c.rrf_score >= $4
    ORDER BY c.rrf_score DESC
    LIMIT $5
    OFFSET $6
    """

    case Repo.query(sql, [query_embedding, query, rrf_k, @min_score_threshold, limit, offset]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, &format_row(&1, columns))}

      {:error, error} ->
        require Logger
        Logger.error("Hybrid search query failed: #{inspect(error)}")
        {:error, {:database_error, error}}
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
