defmodule Doctrans.Chat.RetrievalTest do
  # Each test installs its own embedder on the mock; the queries run under
  # `Doctrans.TaskSupervisor`, which carries `$callers`. The summary line an
  # outage logs is covered by `Doctrans.Chat.RetrievalLogTest`, which has to
  # raise the VM-wide `Logger` level and so runs on its own.
  use Doctrans.DataCase, async: true

  import ExUnit.CaptureLog

  alias Doctrans.Chat
  alias Doctrans.Chat.{ContractProbe, Retrieval, RetrievalProbe}
  alias Doctrans.Documents
  alias Doctrans.Search.{EmbeddingMock, EmbeddingMocks, EmbeddingStub}

  import Doctrans.Fixtures, only: [fake_embedding: 1, indexed_page_fixture: 2]

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

    test "rejects any option but the limit" do
      document = completed_document()

      # The similarity floor is calibrated against the embedding model, not
      # chosen per call; a caller asking for one is a caller to correct.
      assert_raise ArgumentError, ~r/min_similarity/, fn ->
        Retrieval.retrieve(document.id, ["test query"], min_similarity: 0.1)
      end
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

      # One reciprocal rank each: the first rank's and the second rank's.
      scores = passages |> Enum.map(& &1.rrf_score) |> Enum.sort(:desc)
      assert_in_delta Enum.at(scores, 0), 1 / 61, 1.0e-12
      assert_in_delta Enum.at(scores, 1), 1 / 62, 1.0e-12
    end

    test "deduplicates pages across queries" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      # Same query twice should still return the page once
      assert {:ok, passages} = Retrieval.retrieve(document.id, ["test", "test"], limit: 5)

      assert Enum.map(passages, & &1.page_id) == [page.id]
      assert_in_delta hd(passages).rrf_score, 2 / 61, 1.0e-12
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

    test "reports an outage, tagged with the first failure, when every query fails" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      # Distinct reasons per query, so the assertion below pins *which* failure
      # is reported rather than passing for any of them.
      EmbeddingMocks.fail_matching([{"firstq", :circuit_open}, {"secondq", :timeout}])

      capture_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
                 Retrieval.retrieve(document.id, ["firstq", "secondq"])
      end)
    end

    test "reports an outage on a single failing query" do
      # The branch that matters most: the planner and the embedder are the same
      # server, so a planner outage collapses the query list to one and lands
      # here. Untagged, this reads to the user as a generic error rather than as
      # retrieval being down.
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      EmbeddingMocks.fail(:circuit_open)

      capture_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
                 Retrieval.retrieve(document.id, ["refined query"], limit: 1)
      end)
    end

    test "reports crashed queries as an outage without carrying their payload out" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      EmbeddingMocks.exit_with_text()

      capture_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: reason]}} =
                 Retrieval.retrieve(document.id, ["crashq1", "crashq2"])

        # The tag alone. An exit reason carries the query text and its vector,
        # and this reason is rendered -- so it keeps neither.
        assert reason == :query_crashed
        refute inspect(reason) =~ "crashq1"
      end)
    end

    test "treats an embedder that returns no vector as an outage, not as no matches" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})

      # `{:ok, nil}` is a legal success, but nothing can be ranked against a
      # NULL vector: searching on it would report "nothing matched" for a query
      # that never ran.
      EmbeddingMocks.nil_vector()

      capture_log(fn ->
        assert {:error, {:retrieval_unavailable, [reason: :embedding_unavailable]}} =
                 Retrieval.retrieve(document.id, ["nilq1"])
      end)
    end

    test "keeps the results of the queries that succeeded when only some fail" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      # Only the first query fails; the second embeds through the ordinary stub.
      EmbeddingMocks.fail_matching([{"failingquery", :circuit_open}])

      capture_log(fn ->
        assert {:ok, results} = Retrieval.retrieve(document.id, ["failingquery", "good query"])

        assert Enum.map(results, & &1.page_id) == [page.id]
        # Fused from one ranking only, so a single RRF term.
        assert_in_delta hd(results).rrf_score, 1 / 61, 1.0e-12
      end)
    end

    test "skips a query that crashes beside one that succeeds" do
      document = completed_document()
      page = indexed_page_fixture(document, %{page_number: 1})

      # The crash is caught inside the query's own task, so it is a failure of
      # that query alone and the stream, linked to this process, survives it.
      Mox.stub(EmbeddingMock, :generate, fn
        "crashing query", _opts -> exit({:embedding_crashed, "crashing query"})
        query, opts -> EmbeddingStub.generate(query, opts)
      end)

      capture_log(fn ->
        assert {:ok, results} = Retrieval.retrieve(document.id, ["crashing query", "good query"])

        assert Enum.map(results, & &1.page_id) == [page.id]
        assert_in_delta hd(results).rrf_score, 1 / 61, 1.0e-12
      end)
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

  describe "retrieve/3 fusing the rankings of several phrasings" do
    setup do
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

      %{
        document: document,
        queries: ["assets", "liabilities"],
        expected: [shared, liabilities_only, assets_only, lower_assets],
        scores: [1 / 61 + 1 / 62, 1 / 61, 1 / 62, 1 / 63]
      }
    end

    test "ranks a passage several phrasings found above one only a single phrasing found",
         %{document: document, queries: queries, expected: expected, scores: scores} do
      assert {:ok, results} = Retrieval.retrieve(document.id, queries, limit: 4)

      assert Enum.map(results, & &1.chunk_id) == Enum.map(expected, & &1.id)
      assert_received {:contract_embedding, "assets"}
      assert_received {:contract_embedding, "liabilities"}

      for {result, score} <- Enum.zip(results, scores) do
        assert_in_delta result.rrf_score, score, 1.0e-12
      end
    end

    test "a fused passage carries its chunk's text and the best similarity any phrasing gave it",
         %{document: document, queries: queries, expected: expected} do
      assert {:ok, results} = Retrieval.retrieve(document.id, queries, limit: 4)

      for {result, chunk} <- Enum.zip(results, expected) do
        assert result.page_id == chunk.page_id
        assert result.chunk_index == chunk.chunk_index
        assert result.original_markdown == chunk.content
        assert result.translated_markdown == nil
      end

      # Chunk 0 scores 0.8 against "assets" and 0.6 against "liabilities".
      assert_in_delta hd(results).similarity, 0.8, 1.0e-6
    end

    test "the limit applies to the fused ranking", %{document: document, queries: queries} do
      assert {:ok, results} = Retrieval.retrieve(document.id, queries, limit: 4)
      assert {:ok, limited} = Retrieval.retrieve(document.id, queries, limit: 2)

      assert limited == Enum.take(results, 2)
    end
  end

  defp vector(first, second), do: Pgvector.new([first, second | List.duplicate(0.0, 1022)])

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
