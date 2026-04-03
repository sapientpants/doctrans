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
      insert_page_with_embedding(document, 1)

      # Same query twice should still return the page once
      assert {:ok, pages} =
               MultiSearch.search_with_queries(document.id, ["test", "test"], limit: 5)

      page_ids = Enum.map(pages, & &1.page_id)
      assert page_ids == Enum.uniq(page_ids)
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
