defmodule Doctrans.Chat.Retrieval do
  @moduledoc """
  Finds the passages of one Document that bear on a question, from one or more
  phrasings of it.

  Every phrasing is embedded and searched on its own, in parallel, and the
  rankings are fused with Reciprocal Rank Fusion so a passage several phrasings
  agree on outranks one only a single phrasing found. One phrasing is the
  degenerate case: a fusion of one ranking, in its own order.

  A passage is a Chunk when the document has embedded chunks, and a whole Page
  only when no chunk clears the similarity floor. Retrieval is exact: it ranks
  every eligible row of the document rather than the approximate index's
  candidates (see `search_by_embedding/3`).

  Retrieval has one meaning for an empty answer and one for an outage. A
  phrasing whose embedder fails, or succeeds without a vector, never ran, and
  is skipped; the passages come from the phrasings that did run. Only when
  every phrasing failed is the result `{:error, {:retrieval_unavailable, ...}}`,
  carrying the first failure's tag -- so an embedder outage never reaches the
  reader as "the document holds nothing relevant". `{:ok, []}` keeps its own
  meaning: the document was searched and nothing in it matched.

  The similarity floor a passage must clear is calibrated against the
  embedding model, not chosen per call; `:limit` is the only option, and any
  other is rejected.
  """

  alias Doctrans.Deps
  alias Doctrans.Errors
  alias Doctrans.Repo
  alias Doctrans.Search

  require Logger

  @typedoc """
  One retrieved passage.

  Chunk-first: when the document has embedded chunks each passage is one chunk,
  `:original_markdown` is the chunk's text, `:chunk_id` and `:chunk_index` are
  set, and `:translated_markdown` is always `nil` -- chunks carry no
  translation. Only when no chunk clears the floor are whole pages retrieved,
  carrying the page's text in both fields (`:translated_markdown` `nil` until
  the page is translated) and no chunk keys. `Doctrans.Chat` reads the fields
  on that contract: the chunk keys say which text to quote and whether a
  translated copy may outrank it.

  `:rrf_score` is the rank the passage was retrieved by; context restored from
  a saved conversation (`Doctrans.Chat.Conversations`) does not carry it.
  """
  @type result :: %{
          :page_id => Ecto.UUID.t() | nil,
          :page_number => pos_integer(),
          :original_markdown => String.t() | nil,
          :translated_markdown => String.t() | nil,
          :similarity => float(),
          :content_revision => integer() | nil,
          optional(:chunk_id) => Ecto.UUID.t() | nil,
          optional(:chunk_index) => non_neg_integer(),
          optional(:rrf_score) => float()
        }

  # Minimum cosine similarity a passage must reach to be retrieved at all.
  # Cosine similarity: 0 = unrelated, 1 = identical. 0.30 keeps recall high for
  # abstract or analytical questions ("assess the balance sheet") while still
  # filtering clear noise -- lower than library search's 0.55, because a
  # question about one document is answered from passages that paraphrase it,
  # not from pages that name it.
  @similarity_floor 0.30

  @default_limit 3

  @doc """
  Retrieves the passages of `document_id` that bear on `queries`, best first.

  Returns at most `:limit` (default #{@default_limit}) passages, each carrying
  the `:rrf_score` it was ranked by and the best `:similarity` any phrasing
  gave it. No queries is `{:ok, []}`: nothing was asked, so nothing failed.

  Raises `ArgumentError` for an option other than `:limit`.
  """
  @spec retrieve(Ecto.UUID.t(), [String.t()], keyword()) ::
          {:ok, [result()]} | {:error, {:retrieval_unavailable, [reason: atom()]}}
  def retrieve(document_id, queries, opts \\ []) when is_list(queries) do
    limit = opts |> Keyword.validate!(limit: @default_limit) |> Keyword.fetch!(:limit)

    retrieve_with_limit(document_id, queries, limit)
  end

  defp retrieve_with_limit(_document_id, [], _limit), do: {:ok, []}

  defp retrieve_with_limit(document_id, queries, limit) do
    {succeeded, failed} =
      document_id
      |> outcomes(queries, limit)
      |> Enum.split_with(&match?({:ok, _passages}, &1))

    resolve(succeeded, failed, limit)
  end

  # The stream is ordered, so the head of the failures is the first query's.
  # The tag alone is carried out: the detail is logged where it arose, and what
  # reaches the reader is a rendered message, not a payload.
  defp resolve([], [{:error, tag} | _rest] = failed, _limit) do
    log_summary([], failed, 0)

    {:error, {:retrieval_unavailable, [reason: tag]}}
  end

  defp resolve(succeeded, failed, limit) do
    fused =
      succeeded
      |> Enum.map(fn {:ok, passages} -> passages end)
      |> fuse(limit)

    log_summary(succeeded, failed, length(fused))

    {:ok, fused}
  end

  defp log_summary(succeeded, failed, returned) do
    Logger.info(
      "Retrieval: #{length(succeeded) + length(failed)} queries, " <>
        "#{length(succeeded)} succeeded, #{length(failed)} failed, " <>
        "#{returned} results returned"
    )
  end

  # Linked, so the queries die with the turn: `Doctrans.Chat.Agent` runs inside
  # a task the chat session kills when its document goes, and a query left
  # running against rows that are gone would be the leak that kill exists to
  # prevent. (An unlinked stream leaves its tasks running when the caller dies.)
  # The link is safe because `search_one/3` never crashes: a query that raises
  # or exits is caught inside its own task and comes back as a failure of that
  # query alone, which is what partial availability needs.
  defp outcomes(document_id, queries, limit) do
    Doctrans.TaskSupervisor
    |> Task.Supervisor.async_stream(
      queries,
      &search_one(document_id, &1, limit),
      timeout: :infinity,
      max_concurrency: length(queries)
    )
    |> Enum.map(fn {:ok, outcome} -> outcome end)
  end

  # `{:ok, nil}` is a legal embedding result -- see
  # `Doctrans.Search.EmbeddingBehaviour` -- and the one success nothing can be
  # ranked against. Searching on it would answer `{:ok, []}`, an absence of
  # matches, for a query that never ran.
  #
  # Each query fetches a little past the limit so the fusion has candidates to
  # rank beyond the ones every phrasing agrees on.
  defp search_one(document_id, query, limit) do
    result =
      case Deps.embedding().generate(query, []) do
        {:ok, nil} -> {:error, :embedding_unavailable}
        {:ok, embedding} -> search_by_embedding(document_id, embedding, limit + 2)
        {:error, reason} -> {:error, reason}
      end

    with {:error, reason} <- result, do: failed(reason, Errors.tag(reason))
  catch
    kind, reason -> failed({kind, reason}, :query_crashed)
  end

  # Only a tag leaves a failure: the detail is logged here, and the tag is
  # rendered to the reader. An exit reason in particular carries the query text
  # and its vector, and the tag keeps neither.
  defp failed(detail, tag) do
    Logger.warning("Retrieval query failed: #{inspect(detail, limit: 5, printable_limit: 256)}")

    {:error, tag}
  end

  # Each ranking contributes a reciprocal-rank score per passage; the scores of
  # one passage across rankings are summed. A passage's identity is
  # `{page_id, chunk_index}`, with a nil index for a whole page.
  defp fuse(rankings, limit) do
    rankings
    |> Enum.flat_map(&score_ranking/1)
    |> Enum.group_by(fn {identity, _score, _passage} -> identity end)
    |> Enum.map(fn {_identity, entries} -> best_scoring(entries) end)
    |> Enum.sort_by(& &1.rrf_score, :desc)
    |> Enum.take(limit)
  end

  # The smoothing constant is library search's, so a rank is worth the same in
  # both fusions.
  defp score_ranking(passages) do
    k = Search.rrf_k()

    passages
    |> Enum.with_index(1)
    |> Enum.map(fn {passage, rank} ->
      identity = {passage.page_id, Map.get(passage, :chunk_index)}
      {identity, 1.0 / (k + rank), passage}
    end)
  end

  # The passage's text is the same under every phrasing; what differs is the
  # similarity each gave it, and the best one is kept.
  defp best_scoring(entries) do
    rrf_score = Enum.reduce(entries, 0.0, fn {_identity, score, _passage}, acc -> acc + score end)

    {_identity, _score, best} =
      Enum.max_by(entries, fn {_identity, _score, passage} -> passage.similarity end)

    Map.put(best, :rrf_score, rrf_score)
  end

  # Static heredocs; every value reaches Postgres as a bound parameter ($1..$4)
  # via `run_query/5`, which owns the `Repo.query/2` call and its skip.
  @chunk_sql """
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

  @page_sql """
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

  # One phrasing's ranking: chunks first, whole pages only when no chunk
  # clears the floor.
  #
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
  # afterwards. Library search in `Doctrans.Search.HybridQuery` ranks its
  # semantic half the same way, and for the same reason (#218).
  defp search_by_embedding(document_id, query_embedding, limit) do
    case run_query("Chunk", @chunk_sql, document_id, query_embedding, limit) do
      {:ok, []} -> run_query("Page", @page_sql, document_id, query_embedding, limit)
      result -> result
    end
  end

  # Both statements bind the same four parameters in the same order and fail
  # the same way; what differs is the SQL and the row shape, and the row's own
  # columns say which shape it is.
  #
  # `sql` is one of the two static heredocs above, never built from input, and
  # every value reaches Postgres as a bound parameter. Flagged only because the
  # statement arrives in a variable.
  # sobelow_skip ["SQL.Query"]
  defp run_query(label, sql, document_id, query_embedding, limit) do
    params = [query_embedding, Ecto.UUID.dump!(document_id), limit, @similarity_floor]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, &format_row(Map.new(Enum.zip(columns, &1))))}

      {:error, error} ->
        Logger.error(
          "#{label} retrieval query failed: #{inspect(error, limit: 5, printable_limit: 256)}"
        )

        {:error, {:database_error, [reason: error]}}
    end
  end

  # Only the chunk statement selects `chunk_id` and `chunk_index`; a page row
  # carries neither key, which is what `t:result/0` promises.
  defp format_row(row) do
    base = %{
      page_id: uuid_to_string(row["page_id"]),
      page_number: row["page_number"],
      original_markdown: row["original_markdown"],
      translated_markdown: row["translated_markdown"],
      content_revision: row["content_revision"],
      similarity: to_float(row["similarity"])
    }

    case row do
      %{"chunk_id" => chunk_id, "chunk_index" => chunk_index} ->
        Map.merge(base, %{chunk_id: uuid_to_string(chunk_id), chunk_index: chunk_index})

      _page_row ->
        base
    end
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
end
