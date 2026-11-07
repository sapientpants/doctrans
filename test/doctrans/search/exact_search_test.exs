defmodule Doctrans.Search.ExactSearchTest do
  # No retrieval may go through the approximate HNSW index: that scan collects
  # `hnsw.ef_search` candidates from the whole index -- other documents' rows,
  # and the entries of deleted or rolled-back rows vacuum has not yet removed --
  # and filters afterwards, so a row that should match can fall outside the
  # candidate set and the query comes back one row short (#184, #218). Whether
  # the planner takes that path depends on its statistics at the time, so the
  # property is checked on the plans themselves, with sorting disabled: an
  # ORDER BY the approximate index can serve then becomes the planner's only
  # sort-free plan, and it takes it whenever the query shape allows.
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat.Retrieval
  alias Doctrans.Documents.Chunk
  alias Doctrans.Repo
  alias Doctrans.Search
  alias Doctrans.Search.EmbeddingMocks

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

  # Retrieval runs each query in a task under `Doctrans.TaskSupervisor`, which
  # carries the test in `$callers`; library search runs in the test itself.
  @doc false
  def forward_query(_event, _measurements, %{query: sql, params: params}, test_pid) do
    if test_pid in [self() | Process.get(:"$callers", [])] do
      send(test_pid, {:repo_query, sql, params})
    end

    :ok
  end

  describe "Retrieval.retrieve/3" do
    test "the page and chunk queries only reach embeddings through the document",
         %{document: document, target: target} do
      EmbeddingMocks.vector(target.embedding)
      forbid_sorting()

      assert {:ok, [result]} = Retrieval.retrieve(document.id, ["liabilities"])
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

      EmbeddingMocks.vector(target.embedding)
      forbid_sorting()

      assert {:ok, [result]} = Retrieval.retrieve(document.id, ["liabilities"])
      assert result.page_id == target.id
      assert Map.has_key?(result, :chunk_id)

      assert [plan] = vector_query_plans()
      refute plan =~ "_embedding_idx", "approximate index in plan:\n#{plan}"
    end
  end

  describe "search_with_count/2" do
    test "the semantic half ranks every eligible page, not an index's candidates",
         %{off_topic: off_topic, target: target} do
      # The stubbed query vector is `off_topic`'s own, so the semantic half
      # admits that page alone; the full-text half finds both by "page".
      forbid_sorting()

      assert {:ok, %{results: results, total_count: 2}} = Search.search_with_count("page")

      assert Enum.sort(Enum.map(results, & &1.page_id)) ==
               Enum.sort([off_topic.id, target.id])

      assert [plan] = vector_query_plans()
      refute plan =~ "_embedding_idx", "approximate index in plan:\n#{plan}"
    end
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

  # Which way the page's vector points decides whether the query finds it.
  defp indexed_page(document, number, component) do
    indexed_page_fixture(document, %{
      page_number: number,
      original_markdown: "Page #{number}",
      embedding: fake_embedding(component)
    })
  end
end
