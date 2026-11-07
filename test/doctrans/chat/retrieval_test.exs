defmodule Doctrans.Chat.RetrievalTest do
  # Sync: `capture_info_log/1` raises the VM-wide `Logger` level for the
  # duration of a capture, which a concurrent test would see too. The embedding
  # stubs themselves are per test, and the queries run under
  # `Doctrans.TaskSupervisor`, which carries `$callers`.
  use Doctrans.DataCase, async: false

  import ExUnit.CaptureLog

  alias Doctrans.Chat
  alias Doctrans.Chat.{Agent, ContractProbe, Retrieval, RetrievalProbe}
  alias Doctrans.Documents
  alias Doctrans.Search.EmbeddingMocks

  import Doctrans.Fixtures,
    only: [document_fixture: 1, fake_embedding: 1, indexed_page_fixture: 2]

  describe "retrieve/3" do
    test "returns no matches when the document has no pages" do
      document = completed_document()

      assert {:ok, []} = Retrieval.retrieve(document.id, ["test query"])
    end

    test "returns no matches for no queries" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      assert {:ok, []} = Retrieval.retrieve(document.id, [])
    end

    test "embeds exactly the queries it is given" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      RetrievalProbe.install()

      assert {:ok, [_]} = Retrieval.retrieve(document.id, ["refined query"], limit: 1)

      assert_receive {:embedded, "refined query"}
      refute_receive {:embedded, _}
    end

    test "a single query is a fusion of one ranking" do
      document = completed_document()
      first = indexed_page_fixture(document, %{page_number: 1})
      second = indexed_page_fixture(document, %{page_number: 2})

      assert {:ok, passages} = Retrieval.retrieve(document.id, ["test query"])

      assert Enum.sort(Enum.map(passages, & &1.page_id)) == Enum.sort([first.id, second.id])
      assert Enum.sort(Enum.map(passages, & &1.page_number)) == [1, 2]
      assert Enum.all?(passages, &(&1.rrf_score > 0))
    end

    test "fuses different query rankings, retains distinct chunks and limits the best matches" do
      document = completed_document()
      first_page = indexed_page_fixture(document, %{page_number: 1})
      second_page = indexed_page_fixture(document, %{page_number: 2})

      chunks =
        [
          {first_page, 0, vector(0.8, 0.6)},
          {first_page, 1, vector(0.7, -0.7)},
          {first_page, 2, vector(0.6, -0.8)},
          {second_page, 0, vector(0.0, 1.0)}
        ]
        |> Enum.with_index()
        |> Enum.map(fn {{page, chunk_index, embedding}, index} ->
          Repo.insert!(%Doctrans.Documents.Chunk{
            page_id: page.id,
            chunk_index: chunk_index,
            content: "Fact #{index}",
            translated_content: "Translated fact #{index}",
            embedding_status: "completed",
            embedding: embedding
          })
        end)

      probe =
        start_supervised!(
          {ContractProbe,
           %{
             owner: self(),
             embeddings: %{"assets" => vector(1.0, 0.0), "liabilities" => vector(0.0, 1.0)}
           }}
        )

      ContractProbe.install(probe)

      # Assets ranks chunks 0, 1, 2 of the first page; liabilities ranks the
      # second page, then chunk 0. Only chunk 0 receives two reciprocal ranks.
      [shared, assets_only, lower_assets, liabilities_only] = chunks
      expected = [shared, liabilities_only, assets_only, lower_assets]
      scores = [1 / 61 + 1 / 62, 1 / 61, 1 / 62, 1 / 63]
      queries = ["assets", "liabilities"]
      assert {:ok, results} = Retrieval.retrieve(document.id, queries, limit: 4)
      assert Enum.map(results, & &1.chunk_id) == Enum.map(expected, & &1.id)
      assert_received {:contract_embedding, "assets"}
      assert_received {:contract_embedding, "liabilities"}

      Enum.zip([results, expected, scores])
      |> Enum.each(fn {result, chunk, score} ->
        assert result.page_id == chunk.page_id
        assert result.chunk_index == chunk.chunk_index
        assert result.original_markdown == chunk.content
        assert result.translated_markdown == nil
        assert_in_delta result.rrf_score, score, 1.0e-12
      end)

      assert_in_delta hd(results).similarity, 0.8, 1.0e-6

      assert {:ok, limited} = Retrieval.retrieve(document.id, queries, limit: 2)
      assert limited == Enum.take(results, 2)
    end

    test "deduplicates pages across queries" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      # Same query twice should still return the page once
      assert {:ok, pages} = Retrieval.retrieve(document.id, ["test", "test"], limit: 5)

      assert Enum.map(pages, & &1.page_id) == [page.id]
      assert_in_delta hd(pages).rrf_score, 2 / 61, 1.0e-12
    end

    test "retrieved passages carry the source page revision" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      assert {:ok, [result]} = Retrieval.retrieve(document.id, ["original question"], limit: 1)
      assert result.content_revision == page.content_revision
      assert Chat.current_context([result]) == [result]
    end

    test "returns no matches, not an outage, when every query searches and finds nothing" do
      document = completed_document()
      # Opposite direction to the stub's query vector, so the page is searched
      # but never clears the similarity floor.
      indexed_page_fixture(document, %{page_number: 1, embedding: fake_embedding(-0.1)})

      assert {:ok, []} = Retrieval.retrieve(document.id, ["q1", "q2"])
    end

    test "reports an outage, tagged, when every query fails" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      # Distinct reasons per query, so the assertion below pins *which* failure
      # is reported rather than passing for any of them.
      EmbeddingMocks.fail_matching([{"firstq", :circuit_open}, {"secondq", :timeout}])

      log =
        capture_info_log(fn ->
          assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
                   Retrieval.retrieve(document.id, ["firstq", "secondq"])
        end)

      # The summary line has to show the outage, not a quiet empty result.
      assert log =~ "0 succeeded, 2 failed"
    end

    test "reports an outage on a single failing query" do
      # The branch that matters most: the planner and the embedder are the same
      # server, so a planner outage collapses the query list to one and lands
      # here. Untagged, this reads to the user as a generic error rather than as
      # retrieval being down.
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      EmbeddingMocks.fail(:circuit_open)

      capture_info_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
                 Retrieval.retrieve(document.id, ["refined query"], limit: 1)
      end)
    end

    test "reports a crashed query as an outage without carrying its payload out" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      EmbeddingMocks.exit_with_text()

      log =
        capture_info_log(fn ->
          assert {:error, {:retrieval_unavailable, [reason: reason]}} =
                   Retrieval.retrieve(document.id, ["crashq1", "crashq2"])

          # The tag alone. An exit reason carries the query text and its vector,
          # and this reason is rendered -- so it keeps neither.
          assert reason == :task_exited
          refute inspect(reason) =~ "crashq1"
        end)

      assert log =~ "0 succeeded, 2 failed"
    end

    test "treats an embedder that returns no vector as an outage, not as no matches" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      # `{:ok, nil}` is a legal success, but nothing can be ranked against a
      # NULL vector: searching on it would report "nothing matched" for a query
      # that never ran.
      EmbeddingMocks.nil_vector()

      capture_info_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: :embedding_unavailable]}} =
                 Retrieval.retrieve(document.id, ["nilq1"])
      end)
    end

    test "keeps the results of the queries that succeeded when only some fail" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      # Only the first query fails; the second embeds through the ordinary stub.
      EmbeddingMocks.fail_matching([{"failingquery", :circuit_open}])

      log =
        capture_info_log(fn ->
          assert {:ok, results} =
                   Retrieval.retrieve(document.id, ["failingquery", "good query"])

          assert Enum.map(results, & &1.page_id) == [page.id]
          # Fused from one ranking only, so a single RRF term.
          assert_in_delta hd(results).rrf_score, 1 / 61, 1.0e-12
        end)

      assert log =~ "1 succeeded, 1 failed"
    end

    test "the queries die with the caller" do
      # A turn is killed when its document goes; a query left running against
      # rows that are gone would be the leak that kill exists to prevent.
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      barrier = EmbeddingMocks.hold("held query")

      caller =
        Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
          Retrieval.retrieve(document.id, ["held query", "other query"])
        end)

      assert_receive {:embedding_started, ^barrier, query_pid}, 2_000
      monitor = Process.monitor(query_pid)

      Process.exit(caller.pid, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^query_pid, :killed}, 2_000
    end
  end

  describe "through the agent" do
    test "embeds the planned queries and the grader's refined query" do
      document = document_fixture(%{title: "Annual Report", original_filename: "report.pdf"})
      indexed_page_fixture(document, %{original_markdown: "Total assets EUR 120m."})
      RetrievalProbe.install()

      assert {:ok, "Answer.", [_]} =
               Agent.run(document, "assess the balance sheet", [], [], fn _ -> :ok end)

      assert_receive {:embedded, "assess the balance sheet"}
      assert_receive {:embedded, "liquidity and cash reserves"}
      assert_receive {:embedded, "liquidity and cash reserves"}
      refute_receive {:embedded, _}
    end
  end

  defp vector(first, second), do: Pgvector.new([first, second | List.duplicate(0.0, 1022)])

  # The suite runs at :warning, so the summary line an outage has to be visible
  # in is only readable with the level raised for the duration of the capture.
  defp capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp completed_document do
    {:ok, document} =
      Documents.create_document(%{
        status: "completed",
        title: "Test Document",
        original_filename: "test.pdf",
        source_language: "en",
        target_language: "de"
      })

    document
  end
end
