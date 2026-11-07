defmodule Doctrans.Chat.Retrieval do
  @moduledoc """
  Finds the passages of one Document that bear on a question, from one or more
  phrasings of it.

  Every phrasing is embedded and searched on its own, in parallel, and the
  rankings are fused with Reciprocal Rank Fusion so a passage several phrasings
  agree on outranks one only a single phrasing found. One phrasing is the
  degenerate case: a fusion of one ranking, in its own order.

  Retrieval has one meaning for an empty answer and one for an outage. A
  phrasing whose embedder fails, or succeeds without a vector, never ran, and
  is skipped; the passages come from the phrasings that did run. Only when
  every phrasing failed is the result `{:error, {:retrieval_unavailable, ...}}`,
  carrying the first failure's tag -- so an embedder outage never reaches the
  reader as "the document holds nothing relevant". `{:ok, []}` keeps its own
  meaning: the document was searched and nothing in it matched.

  The similarity floor a passage must clear is calibrated against the
  embedding model, not chosen per call; `:limit` is the only option.
  """

  alias Doctrans.Deps
  alias Doctrans.Errors
  alias Doctrans.Search

  require Logger

  # The fusion's smoothing constant. Shared with library search's SQL fusion,
  # where `Doctrans.Search` documents it.
  @rrf_k 60

  @default_limit 3

  @doc """
  Retrieves the passages of `document_id` that bear on `queries`, best first.

  Returns at most `:limit` (default #{@default_limit}) passages as
  `t:Doctrans.Search.document_result/0`, each carrying the `:rrf_score` it was
  ranked by and the best `:similarity` any phrasing gave it. No queries is
  `{:ok, []}`: nothing was asked, so nothing failed.
  """
  @spec retrieve(Ecto.UUID.t(), [String.t()], keyword()) ::
          {:ok, [Search.document_result()]}
          | {:error, {:retrieval_unavailable, [reason: atom()]}}
  def retrieve(document_id, queries, opts \\ [])

  def retrieve(_document_id, [], _opts), do: {:ok, []}

  def retrieve(document_id, queries, opts) when is_list(queries) do
    limit = Keyword.get(opts, :limit, @default_limit)

    {succeeded, failed} =
      document_id
      |> outcomes(queries, limit)
      |> Enum.split_with(&match?({:ok, _passages}, &1))

    resolve(succeeded, failed, queries, limit)
  end

  # The stream is ordered, so the head of the failures is the first query's.
  # The tag alone is carried out: the detail is logged where it arose, and what
  # reaches the reader is a rendered message, not a payload.
  defp resolve([], [{:error, tag} | _rest] = failed, queries, _limit) do
    log_summary(queries, [], failed, 0)

    {:error, {:retrieval_unavailable, [reason: tag]}}
  end

  defp resolve(succeeded, failed, queries, limit) do
    fused =
      succeeded
      |> Enum.map(fn {:ok, passages} -> passages end)
      |> fuse(limit)

    log_summary(queries, succeeded, failed, length(fused))

    {:ok, fused}
  end

  defp log_summary(queries, succeeded, failed, returned) do
    Logger.info(
      "Retrieval: #{length(queries)} queries, #{length(succeeded)} succeeded, " <>
        "#{length(failed)} failed, #{returned} results returned"
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

  # `{:ok, nil}` is a legal embedding result -- see `Search.EmbeddingBehaviour`
  # -- and the one success nothing can be ranked against. Searching on it would
  # answer `{:ok, []}`, an absence of matches, for a query that never ran.
  #
  # Each query fetches a little past the limit so the fusion has candidates to
  # rank beyond the ones every phrasing agrees on.
  #
  # Only a tag leaves a failure: the detail is logged here, and the reason is
  # rendered to the reader. An exit reason in particular carries the query text
  # and its vector, and keeps neither.
  defp search_one(document_id, query, limit) do
    result =
      case Deps.embedding().generate(query, []) do
        {:ok, nil} -> {:error, :embedding_unavailable}
        {:ok, embedding} -> Search.search_by_embedding(document_id, embedding, limit: limit + 2)
        {:error, reason} -> {:error, reason}
      end

    with {:error, reason} <- result do
      Logger.warning("Retrieval query failed: #{inspect(reason, limit: 5, printable_limit: 256)}")
      {:error, Errors.tag(reason)}
    end
  catch
    kind, reason ->
      Logger.warning(
        "Retrieval query #{kind}: #{inspect(reason, limit: 5, printable_limit: 256)}"
      )

      {:error, :task_exited}
  end

  # Each ranking contributes a reciprocal-rank score per passage; the scores of
  # one passage across rankings are summed. A passage is a chunk, or the whole
  # page when the document has no chunks to retrieve, so its identity is
  # `{page_id, chunk_index}` with a nil index for a page.
  defp fuse(rankings, limit) do
    rankings
    |> Enum.flat_map(&score_ranking/1)
    |> Enum.group_by(fn {identity, _score, _passage} -> identity end)
    |> Enum.map(fn {_identity, entries} -> best_scoring(entries) end)
    |> Enum.sort_by(& &1.rrf_score, :desc)
    |> Enum.take(limit)
  end

  defp score_ranking(passages) do
    passages
    |> Enum.with_index(1)
    |> Enum.map(fn {passage, rank} ->
      identity = {passage.page_id, Map.get(passage, :chunk_index)}
      {identity, 1.0 / (@rrf_k + rank), passage}
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
end
