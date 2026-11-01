defmodule Doctrans.Search.ExactDocumentSearchTest do
  # Retrieval within one document must never go through the approximate HNSW
  # index: that scan collects `hnsw.ef_search` candidates from the whole index
  # and filters by document afterwards, so a document's page can fall outside
  # the candidate set and the query comes back one row short (#184). Whether the
  # planner takes that path depends on its statistics at the time, so the
  # property is checked on the plans themselves, with sorting disabled: an
  # ORDER BY the approximate index can serve then becomes the planner's only
  # sort-free plan, and it takes it whenever the query shape allows.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Repo
  alias Doctrans.Search

  import Doctrans.Fixtures

  @query_event [:doctrans, :repo, :query]

  setup do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, @query_event, &__MODULE__.forward_query/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    document = document_fixture(%{status: "completed", total_pages: 2})
    off_topic = indexed_page(document, 1, 0.1)
    target = indexed_page(document, 2, -0.1)
    %{document: document, off_topic: off_topic, target: target}
  end

  @doc false
  def forward_query(_event, _measurements, %{query: sql, params: params}, test_pid) do
    if self() == test_pid, do: send(test_pid, {:repo_query, sql, params})
    :ok
  end

  test "the page and chunk queries only reach embeddings through the document",
       %{document: document, target: target} do
    forbid_sorting()

    assert {:ok, [result]} = Search.search_by_embedding(document.id, target.embedding)
    assert result.page_id == target.id

    plans = vector_query_plans()
    assert length(plans) == 2, "expected a chunk query and a page query, got #{length(plans)}"

    for plan <- plans do
      refute plan =~ "_embedding_idx", "approximate index in plan:\n#{plan}"
    end
  end

  test "a chunk match is found the same way", %{document: document, target: target} do
    Repo.insert!(%Chunk{
      page_id: target.id,
      chunk_index: 0,
      content: "Liabilities are 75 million euros.",
      embedding_status: "completed",
      embedding: target.embedding
    })

    forbid_sorting()

    assert {:ok, [result]} = Search.search_by_embedding(document.id, target.embedding)
    assert result.page_id == target.id
    assert Map.has_key?(result, :chunk_id)

    assert [plan] = vector_query_plans()
    refute plan =~ "_embedding_idx", "approximate index in plan:\n#{plan}"
  end

  # Scoped to the sandbox transaction, so it lasts exactly as long as the test.
  defp forbid_sorting, do: Repo.query!("SET LOCAL enable_sort = off")

  # EXPLAIN of every query the test process ran against an embedding, with the
  # parameters it ran with, as one string per query.
  defp vector_query_plans do
    collect_queries([])
    |> Enum.filter(fn {sql, _params} -> sql =~ "<=>" end)
    |> Enum.map(fn {sql, params} ->
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      rows |> List.flatten() |> Enum.join("\n")
    end)
  end

  defp collect_queries(acc) do
    receive do
      {:repo_query, sql, params} -> collect_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp indexed_page(document, number, component) do
    Repo.insert!(%Page{
      document_id: document.id,
      page_number: number,
      original_markdown: "Page #{number}",
      extraction_status: "completed",
      embedding_status: "completed",
      embedding: Pgvector.new(List.duplicate(component, 1024))
    })
  end
end
