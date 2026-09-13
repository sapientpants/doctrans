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
          # Present only on results fused by `Doctrans.Chat.MultiSearch`.
          optional(:rrf_score) => float()
        }

  alias Doctrans.Repo
  alias Doctrans.Search.HybridQuery

  require Logger

  # Allow embedding module to be configured for testing
  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end

  @doc """
  Performs hybrid search across all pages.

  Returns a list of search results sorted by RRF score (combination of
  semantic similarity and full-text search ranking).

  Use `search_with_count/2` when the total number of matches is wanted too --
  it is the same statement, the total comes back for free, and it reports
  whether the ranking was hybrid or degraded to keyword-only. This function
  degrades the same way; it just does not say so, which is why nothing in
  `lib/` calls it.

  ## Options

  - `:limit` - Maximum number of results (default: 20)
  - `:offset` - Matches to skip before the first result (default: 0)
  - `:rrf_k` - RRF smoothing constant (default: 60, higher = smoother ranking)
  """
  @spec search(String.t() | nil, keyword()) ::
          {:ok, [hybrid_result()]} | {:error, Doctrans.Errors.reason()}
  def search(query, opts \\ [])
  def search("", _opts), do: {:ok, []}
  def search(nil, _opts), do: {:ok, []}

  # RRF constant k - higher values give smoother ranking
  @default_rrf_k 60

  # Minimum RRF score threshold to filter out irrelevant results
  # With k=60, a single match at rank 1 gives score ~0.0164 (1/61)
  @min_score_threshold 0.01

  @default_limit 20

  def search(query, opts) when is_binary(query) do
    with {:ok, %{results: results}} <- search_with_count(query, opts) do
      {:ok, results}
    end
  end

  @doc """
  Performs hybrid search and counts every match, from one query embedding and
  one statement.

  The page of results and the total come back from a single SELECT: the count is
  a window over the same filtered rows the page is drawn from. So a query costs
  one inference call, one ranking pass, and leaves no window in which indexing
  can land between a count and a search and move the total.

  Takes `search/2`'s options. The total describes the whole match set rather
  than the page returned -- except past the end of it: an `:offset` beyond the
  last match returns no rows, and with no rows there is no window to count, so
  `:total_count` is 0. A caller paginating past the end therefore sees an empty
  result set, which is what it should render anyway.

  `:retrieval` names the ranking that produced the page: `:hybrid` when the
  query was embedded, `:keyword_only` when it could not be and the full-text
  half answered alone. A caller has to be able to tell a degraded search apart
  from a search that found nothing, so this reports the mode rather than
  failing.
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
        min_score: min_score(retrieval),
        limit: limit,
        offset: offset
      )
    end
  end

  # Nothing was asked, so nothing was retrieved -- and no ranking was skipped,
  # which is why the mode is the healthy one rather than a degraded one.
  defp empty_page, do: %{results: [], total_count: 0, retrieval: :hybrid}

  # The floor is there to cut the semantic half's noise: that half has no
  # similarity threshold, so it ranks the whole corpus and its deep ranks are
  # not matches in any meaningful sense (PLAN.md S03). Keyword-only retrieval
  # has no such half -- every row it ranks cleared a tsquery match -- and the
  # fused score collapses to `1/(rrf_k + fts_rank)`, which falls under 0.01 at
  # rank 41 for the default k=60. Keeping the floor there would silently drop
  # every match past the 40th *and* shrink the `COUNT(*) OVER ()` total to
  # match, reporting "40 results" for a term that matched five hundred pages.
  defp min_score(:hybrid), do: @min_score_threshold
  defp min_score(:keyword_only), do: 0.0

  # An embedding server outage must not read as "nothing matched": rank on the
  # full-text half alone rather than failing a search the keyword index can
  # still answer, and hand back the mode so the caller can say which it got.
  # `{:ok, nil}` is a legal embedding result (`EmbeddingBehaviour`) and is the
  # same situation -- reporting `:hybrid` for it would claim a ranking that did
  # not run. Either way `nil` reaches the statement as a NULL vector, which
  # `HybridQuery.run/3` turns into an empty semantic ranking.
  defp query_embedding(query) do
    case embedding_module().generate(query, []) do
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

  A list of maps containing:
  - `:page_id` - The page's UUID
  - `:page_number` - Page number in the document
  - `:original_markdown` - Original extracted text
  - `:translated_markdown` - Translated text (if available)
  - `:content_revision` - Source page revision the text came from
  - `:similarity` - Cosine similarity score (0-1, higher is better)
  """
  @spec search_in_document(Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, [document_result()]} | {:error, Doctrans.Errors.reason()}
  def search_in_document(document_id, query, opts \\ [])
  def search_in_document(_document_id, "", _opts), do: {:ok, []}
  def search_in_document(_document_id, nil, _opts), do: {:ok, []}

  def search_in_document(document_id, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 3)
    min_similarity = Keyword.get(opts, :min_similarity, @chat_similarity_threshold)

    with {:ok, query_embedding} <- embedding_module().generate(query, []) do
      search_by_embedding(document_id, query_embedding,
        limit: limit,
        min_similarity: min_similarity
      )
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

  # Static heredoc; every value reaches Postgres as a bound parameter ($1..$4) via
  # Repo.query/2. Flagged only because the query is bound to a variable named `sql`.
  # sobelow_skip ["SQL.Query"]
  defp execute_chunk_search(document_id, query_embedding, limit, min_similarity) do
    sql = """
    SELECT
      c.id as chunk_id,
      c.page_id,
      p.page_number,
      c.content as original_markdown,
      NULL::text as translated_markdown,
      c.chunk_index,
      p.content_revision,
      1 - (c.embedding <=> $1::vector) as similarity
    FROM chunks c
    JOIN pages p ON c.page_id = p.id
    WHERE p.document_id = $2
      AND p.extraction_status = 'completed'
      AND c.embedding IS NOT NULL
      AND (1 - (c.embedding <=> $1::vector)) >= $4
    ORDER BY c.embedding <=> $1::vector ASC
    LIMIT $3
    """

    case Repo.query(sql, [query_embedding, Ecto.UUID.dump!(document_id), limit, min_similarity]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, &format_chunk_search_row(&1, columns))}

      {:error, error} ->
        Logger.error(
          "Chunk search query failed: #{inspect(error, limit: 5, printable_limit: 256)}"
        )

        {:error, {:database_error, [reason: error]}}
    end
  end

  # Static heredoc; $1..$4 are bound parameters, nothing is interpolated into the SQL.
  # sobelow_skip ["SQL.Query"]
  defp execute_page_search(document_id, query_embedding, limit, min_similarity) do
    sql = """
    SELECT
      p.id as page_id,
      p.page_number,
      p.original_markdown,
      p.translated_markdown,
      p.content_revision,
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
        {:ok, Enum.map(rows, &format_page_search_row(&1, columns))}

      {:error, error} ->
        Logger.error(
          "Page search query failed: #{inspect(error, limit: 5, printable_limit: 256)}"
        )

        {:error, {:database_error, [reason: error]}}
    end
  end

  defp format_chunk_search_row(row, columns) do
    result = Enum.zip(columns, row) |> Map.new()

    %{
      chunk_id: uuid_to_string(result["chunk_id"]),
      page_id: uuid_to_string(result["page_id"]),
      page_number: result["page_number"],
      original_markdown: result["original_markdown"],
      translated_markdown: result["translated_markdown"],
      chunk_index: result["chunk_index"],
      content_revision: result["content_revision"],
      similarity: to_float(result["similarity"])
    }
  end

  defp format_page_search_row(row, columns) do
    result = Enum.zip(columns, row) |> Map.new()

    %{
      page_id: uuid_to_string(result["page_id"]),
      page_number: result["page_number"],
      original_markdown: result["original_markdown"],
      translated_markdown: result["translated_markdown"],
      content_revision: result["content_revision"],
      similarity: to_float(result["similarity"])
    }
  end

  defp execute_hybrid_search(query, query_embedding, retrieval, query_opts) do
    with {:ok, %{rows: rows, columns: columns}} <-
           HybridQuery.run(query, query_embedding, query_opts) do
      {:ok,
       %{
         results: Enum.map(rows, &format_row(&1, columns)),
         total_count: total_count(rows, columns),
         retrieval: retrieval
       }}
    end
  end

  # Every row carries the same window total, so the first one answers for all of
  # them. No rows means this page of the match set is empty and the window has
  # nothing to report -- see `search_with_count/2` on paginating past the end.
  defp total_count([], _columns), do: 0

  defp total_count([row | _rest], columns) do
    columns
    |> Enum.zip(row)
    |> Map.new()
    |> Map.fetch!("total_count")
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
