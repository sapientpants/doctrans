defmodule Doctrans.Chat.MultiSearchTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Chat.MultiSearch
  alias Doctrans.Documents

  describe "search_with_queries/3" do
    test "returns empty results when no pages exist" do
      document = create_document(status: "completed")

      assert {:ok, []} = MultiSearch.search_with_queries(document.id, ["test query"])
    end

    test "returns pages matching a single query" do
      document = create_document(status: "completed")
      insert_page_with_embedding(document, 1)
      insert_page_with_embedding(document, 2)

      assert {:ok, pages} = MultiSearch.search_with_queries(document.id, ["test query"])

      assert pages != []
      assert Enum.all?(pages, &Map.has_key?(&1, :page_number))
    end

    test "merges results from multiple queries via RRF" do
      document = create_document(status: "completed")
      insert_page_with_embedding(document, 1)
      insert_page_with_embedding(document, 2)
      insert_page_with_embedding(document, 3)

      queries = ["first query", "second query", "third query"]

      assert {:ok, pages} = MultiSearch.search_with_queries(document.id, queries, limit: 3)

      assert length(pages) <= 3
      # Each page should have an RRF score from merging
      assert Enum.all?(pages, &Map.has_key?(&1, :rrf_score))
    end

    test "respects limit option" do
      document = create_document(status: "completed")

      for i <- 1..5, do: insert_page_with_embedding(document, i)

      assert {:ok, pages} =
               MultiSearch.search_with_queries(document.id, ["query 1", "query 2"], limit: 2)

      assert length(pages) <= 2
    end

    test "retains distinct chunks per page and fuses only matching chunk ranks" do
      document = create_document(status: "completed")
      first_page = insert_page_with_embedding(document, 1)
      second_page = insert_page_with_embedding(document, 2)

      chunks =
        [{first_page, 0}, {first_page, 1}, {first_page, 2}, {second_page, 0}]
        |> Enum.with_index()
        |> Enum.map(fn {{page, chunk_index}, index} ->
          Repo.insert!(%Doctrans.Documents.Chunk{
            page_id: page.id,
            chunk_index: chunk_index,
            content: "Fact #{index}",
            translated_content: "Translated fact #{index}",
            embedding_status: "completed",
            embedding: Pgvector.new([0.1 + index * 0.1 | List.duplicate(0.1, 1023)])
          })
        end)

      queries = ["first query", "second query"]
      assert {:ok, results} = MultiSearch.search_with_queries(document.id, queries, limit: 4)
      assert Enum.map(results, & &1.chunk_id) == Enum.map(chunks, & &1.id)

      results
      |> Enum.zip(chunks)
      |> Enum.with_index(1)
      |> Enum.each(fn {{result, chunk}, rank} ->
        assert result.page_id == chunk.page_id
        assert result.chunk_index == chunk.chunk_index
        assert result.original_markdown == chunk.content
        assert result.translated_markdown == nil
        assert_in_delta result.rrf_score, 2 / (60 + rank), 1.0e-12
      end)

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
  end

  defp create_document(opts) do
    attrs =
      Enum.into(opts, %{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de"
      })

    {:ok, document} = Documents.create_document(attrs)
    document
  end

  defp insert_page_with_embedding(document, page_number) do
    embedding = Pgvector.new(List.duplicate(0.1, 1024))

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
