defmodule Doctrans.Chat.MultiSearchTest do
  use Doctrans.DataCase, async: false

  import ExUnit.CaptureLog

  alias Doctrans.Chat.{ContractProbe, MultiSearch}
  alias Doctrans.Documents
  alias Doctrans.Search.EmbeddingErrorStub
  alias Doctrans.Search.EmbeddingExitStub
  alias Doctrans.Search.EmbeddingNilStub
  alias Doctrans.TestEnv

  describe "search_with_queries/3" do
    test "returns empty results when no pages exist" do
      document = create_document(status: "completed")

      assert {:ok, []} = MultiSearch.search_with_queries(document.id, ["test query"])
    end

    test "returns pages matching a single query" do
      document = create_document(status: "completed")
      first = insert_page_with_embedding(document, 1)
      second = insert_page_with_embedding(document, 2)

      assert {:ok, pages} = MultiSearch.search_with_queries(document.id, ["test query"])

      assert Enum.sort(Enum.map(pages, & &1.page_id)) == Enum.sort([first.id, second.id])
      assert Enum.sort(Enum.map(pages, & &1.page_number)) == [1, 2]
    end

    test "fuses different query rankings, retains distinct chunks and limits the best matches" do
      document = create_document(status: "completed")
      first_page = insert_page_with_embedding(document, 1)
      second_page = insert_page_with_embedding(document, 2)

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

      TestEnv.put_env(:chat_contract_probe, probe)
      TestEnv.put_env(:embedding_module, ContractProbe)

      # Assets ranks chunks 0, 1, 2 of the first page; liabilities ranks the
      # second page, then chunk 0. Only chunk 0 receives two reciprocal ranks.
      [shared, assets_only, lower_assets, liabilities_only] = chunks
      expected = [shared, liabilities_only, assets_only, lower_assets]
      scores = [1 / 61 + 1 / 62, 1 / 61, 1 / 62, 1 / 63]
      queries = ["assets", "liabilities"]
      assert {:ok, results} = MultiSearch.search_with_queries(document.id, queries, limit: 4)
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

      assert {:ok, limited} = MultiSearch.search_with_queries(document.id, queries, limit: 2)
      assert limited == Enum.take(results, 2)
    end

    test "returns ok even when all queries find no results" do
      document = create_document(status: "completed")

      assert {:ok, []} =
               MultiSearch.search_with_queries(document.id, ["q1", "q2", "q3"])
    end

    test "returns ok with empty list for empty queries" do
      document = create_document(status: "completed")

      assert {:ok, []} = MultiSearch.search_with_queries(document.id, [])
    end

    test "deduplicates pages across queries" do
      document = create_document(status: "completed")
      page = insert_page_with_embedding(document, 1)

      # Same query twice should still return the page once
      assert {:ok, pages} =
               MultiSearch.search_with_queries(document.id, ["test", "test"], limit: 5)

      page_ids = Enum.map(pages, & &1.page_id)
      assert page_ids == [page.id]
      assert_in_delta hd(pages).rrf_score, 2 / 61, 1.0e-12
    end

    test "reports an outage when every query fails" do
      document = create_document(status: "completed")
      insert_page_with_embedding(document, 1)

      # Distinct reasons per query, so the assertion below pins *which* failure
      # is reported rather than passing for any of them.
      TestEnv.put_env(:embedding_module, EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_plan, [{"firstq", :circuit_open}, {"secondq", :timeout}])

      log =
        capture_info_log(fn ->
          # `Doctrans.Chat.retrieve/4` is what tags this as an outage; here the
          # bare reason is the contract, and it is the first query's.
          assert {:error, :circuit_open} =
                   MultiSearch.search_with_queries(document.id, ["firstq", "secondq"])
        end)

      # The summary line has to show the outage, not a quiet empty result.
      assert log =~ "0 succeeded, 2 failed"
    end

    test "reports a crashed query as an outage without carrying its payload out" do
      document = create_document(status: "completed")
      insert_page_with_embedding(document, 1)

      TestEnv.put_env(:embedding_module, EmbeddingExitStub)

      log =
        capture_info_log(fn ->
          assert {:error, reason} =
                   MultiSearch.search_with_queries(document.id, ["crashq1", "crashq2"])

          # The tag alone. An exit reason carries the query text and its vector,
          # and this reason is rendered -- so it keeps neither.
          assert reason == :task_exited
          refute inspect(reason) =~ "crashq1"
        end)

      assert log =~ "0 succeeded, 2 failed"
    end

    test "treats an embedding that returns no vector as an outage, not as no matches" do
      document = create_document(status: "completed")
      insert_page_with_embedding(document, 1)

      # `{:ok, nil}` is a legal success, but nothing can be ranked against a
      # NULL vector: searching on it would report "nothing matched" for a query
      # that never ran.
      TestEnv.put_env(:embedding_module, EmbeddingNilStub)

      capture_info_log(fn ->
        assert {:error, :embedding_unavailable} =
                 MultiSearch.search_with_queries(document.id, ["nilq1", "nilq2"])
      end)
    end

    test "keeps the results of the queries that succeeded when only some fail" do
      document = create_document(status: "completed")
      page = insert_page_with_embedding(document, 1)

      # Only the first query fails; the second embeds through the ordinary stub.
      TestEnv.put_env(:embedding_module, EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_plan, [{"failingquery", :circuit_open}])

      log =
        capture_info_log(fn ->
          assert {:ok, results} =
                   MultiSearch.search_with_queries(document.id, ["failingquery", "good query"])

          assert Enum.map(results, & &1.page_id) == [page.id]
          # Fused from one ranked list only, so a single RRF term.
          assert_in_delta hd(results).rrf_score, 1 / 61, 1.0e-12
        end)

      assert log =~ "1 succeeded, 1 failed"
    end

    test "returns no matches, not an outage, when every query searches and finds nothing" do
      document = create_document(status: "completed")
      # Opposite direction to the stub's query vector, so the page is searched
      # but never clears the similarity threshold.
      insert_page_with_embedding(document, 1, List.duplicate(-0.1, 1024))

      assert {:ok, []} = MultiSearch.search_with_queries(document.id, ["q1", "q2"])
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

  defp create_document(opts) do
    attrs =
      Enum.into(opts, %{
        title: "Test Document",
        original_filename: "test.pdf",
        source_language: "en",
        target_language: "de"
      })

    {:ok, document} = Documents.create_document(attrs)
    document
  end

  defp insert_page_with_embedding(document, page_number, values \\ List.duplicate(0.1, 1024)) do
    embedding = Pgvector.new(values)

    Doctrans.Repo.insert!(%Doctrans.Documents.Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: page_number,
      image_path: "documents/#{document.id}/pages/page_#{page_number}.png",
      original_markdown: "Content of page #{page_number}",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: embedding
    })
  end
end
