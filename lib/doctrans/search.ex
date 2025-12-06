defmodule Doctrans.Search do
  @moduledoc """
  Hybrid search combining semantic similarity and keyword matching.

  Searches across page content (original markdown) and returns
  matching pages with their parent documents.
  """

  import Ecto.Query
  alias Doctrans.Repo
  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Search.Embedding

  @doc """
  Performs hybrid search across all pages.

  Returns a list of search results sorted by relevance score.
  Each result includes the page, document, and match context.

  ## Options

  - `:limit` - Maximum number of results (default: 20)
  - `:semantic_weight` - Weight for semantic similarity (default: 0.5)
  - `:keyword_weight` - Weight for keyword matching (default: 0.5)
  """
  def search(query, opts \\ [])
  def search("", _opts), do: {:ok, []}
  def search(nil, _opts), do: {:ok, []}

  # Minimum score threshold to filter out irrelevant results
  # With 0.5/0.5 weights, this requires either a keyword match or very high semantic similarity
  @min_score_threshold 0.5

  def search(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    semantic_weight = Keyword.get(opts, :semantic_weight, 0.5)
    keyword_weight = Keyword.get(opts, :keyword_weight, 0.5)

    with {:ok, query_embedding} <- Embedding.generate(query) do
      results =
        hybrid_search_query(query, query_embedding, semantic_weight, keyword_weight)
        |> Repo.all()
        |> Enum.map(&format_result/1)
        |> Enum.filter(fn r -> r.score >= @min_score_threshold end)
        |> Enum.take(limit)

      {:ok, results}
    end
  end

  defp hybrid_search_query(query, query_embedding, semantic_weight, keyword_weight) do
    # Normalize the query for keyword search
    keyword_pattern = "%#{String.downcase(query)}%"

    from p in Page,
      join: d in Document,
      on: p.document_id == d.id,
      where: d.status == "completed",
      where: p.extraction_status == "completed",
      select: %{
        page_id: p.id,
        document_id: d.id,
        document_title: d.title,
        page_number: p.page_number,
        image_path: p.image_path,
        original_markdown: p.original_markdown,
        translated_markdown: p.translated_markdown,
        # Semantic similarity score (1 - cosine distance)
        semantic_score:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN 1 - (? <=> ?::vector) ELSE 0 END",
            p.embedding,
            p.embedding,
            ^query_embedding
          ),
        # Keyword match score (boolean as 0 or 1)
        keyword_score:
          fragment(
            "CASE WHEN LOWER(?) LIKE ? OR LOWER(?) LIKE ? THEN 1.0 ELSE 0.0 END",
            p.original_markdown,
            ^keyword_pattern,
            p.translated_markdown,
            ^keyword_pattern
          )
      },
      # Filter: must have embedding OR match keywords
      # Results are further filtered by score threshold in the caller
      where:
        not is_nil(p.embedding) or
          ilike(p.original_markdown, ^keyword_pattern) or
          ilike(p.translated_markdown, ^keyword_pattern),
      # Limit initial results to avoid processing too many rows
      limit: 100,
      order_by: [
        desc:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN 1 - (? <=> ?::vector) ELSE 0 END * ? + CASE WHEN LOWER(?) LIKE ? OR LOWER(?) LIKE ? THEN 1.0 ELSE 0.0 END * ?",
            p.embedding,
            p.embedding,
            ^query_embedding,
            ^semantic_weight,
            p.original_markdown,
            ^keyword_pattern,
            p.translated_markdown,
            ^keyword_pattern,
            ^keyword_weight
          )
      ]
  end

  defp format_result(row) do
    # Calculate combined score (handle nil values and Decimal types)
    semantic = to_float(row.semantic_score)
    keyword = to_float(row.keyword_score)
    score = semantic * 0.5 + keyword * 0.5

    %{
      page_id: row.page_id,
      document_id: row.document_id,
      document_title: row.document_title,
      page_number: row.page_number,
      image_path: row.image_path,
      score: score,
      snippet: extract_snippet(row.translated_markdown || row.original_markdown, 200)
    }
  end

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
