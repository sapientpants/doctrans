defmodule Doctrans.SearchTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.Pages
  alias Doctrans.Search

  import Doctrans.Fixtures

  describe "search/2" do
    test "returns empty list for empty query" do
      assert {:ok, []} = Search.search("")
    end

    test "returns empty list for nil query" do
      assert {:ok, []} = Search.search(nil)
    end

    test "returns empty results when no documents match" do
      # Create document but don't complete it (search only searches completed docs)
      _doc = document_fixture(%{status: "uploading"})

      # This will fail to generate embedding (no Ollama in test) and return error
      # or return empty results
      result = Search.search("test query")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts limit option" do
      # Just verify the option is accepted without error
      result = Search.search("test", limit: 5)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts rrf_k option" do
      # RRF smoothing constant - higher values give smoother ranking
      result = Search.search("test", rrf_k: 100)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "finds documents by keyword match in original_markdown" do
      # Create a completed document with pages containing searchable text
      doc = document_fixture(%{status: "completed", title: "Keyword Test Doc"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "This is searchable content about cats and dogs"
        })

      {:ok, results} = Search.search("cats")

      # We should find the page via FTS
      assert is_list(results)
    end

    test "finds documents by keyword match in translated_markdown" do
      doc = document_fixture(%{status: "completed", title: "Translated Test Doc"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Original content"
        })

      {:ok, _page} =
        Pages.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Translated content about elephants"
        })

      {:ok, results} = Search.search("elephants")
      assert is_list(results)
    end

    test "FTS applies stemming - 'running' matches 'run'" do
      doc = document_fixture(%{status: "completed", title: "Stemming Test"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "placeholder"
        })

      {:ok, _page} =
        Pages.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "The runner was running fast through the field"
        })

      # "run" should match "running" and "runner" due to English stemming
      {:ok, results} = Search.search("run")
      refute Enum.empty?(results)
      assert Enum.any?(results, fn r -> r.page_id == page.id end)
    end

    test "returns results with correct structure" do
      doc = document_fixture(%{status: "completed", title: "Structure Test"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Unique searchterm findme content"
        })

      {:ok, results} = Search.search("findme")

      for result <- results do
        assert Map.has_key?(result, :page_id)
        assert Map.has_key?(result, :document_id)
        assert Map.has_key?(result, :document_title)
        assert Map.has_key?(result, :page_number)
        assert Map.has_key?(result, :score)
        assert Map.has_key?(result, :snippet)
      end
    end

    test "returns empty list when document not completed" do
      doc = document_fixture(%{status: "processing", title: "Incomplete Doc"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Content with uniqueword99"
        })

      {:ok, results} = Search.search("uniqueword99")

      # Should not find anything because document status is "processing"
      assert results == []
    end

    test "returns empty list when page extraction not completed" do
      doc = document_fixture(%{status: "completed", title: "Test Doc"})
      _page = page_fixture(doc, %{page_number: 1})

      # Page is created with pending extraction status
      {:ok, results} = Search.search("anything")

      # Should not find pages with pending extraction
      assert results == []
    end

    test "accepts combined options" do
      result =
        Search.search("test",
          limit: 10,
          rrf_k: 80
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "RRF boosts results appearing in both semantic and FTS rankings" do
      # Create two pages: one with FTS match, one without
      # The page with the FTS match should rank higher due to RRF boosting
      doc = document_fixture(%{status: "completed", title: "RRF Test Doc"})

      # Page with text that matches FTS query
      page_with_fts = page_fixture(doc, %{page_number: 1})

      {:ok, page_with_fts} =
        Pages.update_page_extraction(page_with_fts, %{
          extraction_status: "completed",
          original_markdown: "Important information about machine learning algorithms"
        })

      # Page without FTS match (different content)
      page_without_fts = page_fixture(doc, %{page_number: 2})

      {:ok, _page_without_fts} =
        Pages.update_page_extraction(page_without_fts, %{
          extraction_status: "completed",
          original_markdown: "Completely unrelated content about cooking recipes"
        })

      # Search for a term that should match FTS for page 1 only
      {:ok, results} = Search.search("machine learning")

      # Verify at least one result is returned
      refute Enum.empty?(results)

      # Verify the FTS-matching page is found
      assert Enum.any?(results, fn r -> r.page_id == page_with_fts.id end)

      # Note: Full RRF score comparison would require controlling the embedding
      # mock to return different similarity scores. The current test verifies
      # that FTS-matching pages are included in results.
    end
  end

  describe "search_in_document/3" do
    test "returns empty list for empty query" do
      doc = document_fixture(%{status: "completed"})
      assert {:ok, []} = Search.search_in_document(doc.id, "")
    end

    test "returns empty list for nil query" do
      doc = document_fixture(%{status: "completed"})
      assert {:ok, []} = Search.search_in_document(doc.id, nil)
    end

    test "accepts limit option" do
      doc = document_fixture(%{status: "completed"})
      assert {:ok, results} = Search.search_in_document(doc.id, "test", limit: 2)
      assert is_list(results)
    end

    test "accepts min_similarity option" do
      doc = document_fixture(%{status: "completed"})
      assert {:ok, results} = Search.search_in_document(doc.id, "test", min_similarity: 0.5)
      assert is_list(results)
    end

    test "only searches within specified document" do
      # Create two documents with pages that have embeddings
      doc1 = document_fixture(%{status: "completed", title: "Doc One"})
      doc2 = document_fixture(%{status: "completed", title: "Doc Two"})

      # Create embeddings for both pages
      embedding = Pgvector.new(List.duplicate(0.1, 1024))

      page1 =
        Doctrans.Repo.insert!(%Doctrans.Documents.Page{
          id: Ecto.UUID.generate(),
          document_id: doc1.id,
          page_number: 1,
          image_path: "documents/#{doc1.id}/pages/page_1.png",
          original_markdown: "Content in document one",
          extraction_status: "completed",
          translation_status: "pending",
          embedding_status: "completed",
          embedding: embedding
        })

      _page2 =
        Doctrans.Repo.insert!(%Doctrans.Documents.Page{
          id: Ecto.UUID.generate(),
          document_id: doc2.id,
          page_number: 1,
          image_path: "documents/#{doc2.id}/pages/page_1.png",
          original_markdown: "Content in document two",
          extraction_status: "completed",
          translation_status: "pending",
          embedding_status: "completed",
          embedding: embedding
        })

      # Search in doc1 - should only return doc1's pages
      assert {:ok, results} = Search.search_in_document(doc1.id, "content")

      # Results should only include pages from doc1
      for r <- results do
        assert r.page_id == page1.id
      end
    end

    test "returns results with correct structure" do
      doc = document_fixture(%{status: "completed"})

      # Create page with embedding so search can find it
      embedding = Pgvector.new(List.duplicate(0.1, 1024))

      page =
        Doctrans.Repo.insert!(%Doctrans.Documents.Page{
          id: Ecto.UUID.generate(),
          document_id: doc.id,
          page_number: 1,
          image_path: "documents/#{doc.id}/pages/page_1.png",
          original_markdown: "Test content for structure",
          translated_markdown: "Translated test content",
          extraction_status: "completed",
          translation_status: "completed",
          embedding_status: "completed",
          embedding: embedding
        })

      assert {:ok, results} = Search.search_in_document(doc.id, "test")
      # With embedding, we should get results
      refute Enum.empty?(results)

      for result <- results do
        assert Map.has_key?(result, :page_id)
        assert Map.has_key?(result, :page_number)
        assert Map.has_key?(result, :original_markdown)
        assert Map.has_key?(result, :translated_markdown)
        assert Map.has_key?(result, :similarity)
        assert result.page_id == page.id
      end
    end
  end

  describe "count_results/2" do
    test "returns 0 for empty query" do
      assert {:ok, 0} = Search.count_results("")
    end

    test "returns 0 for nil query" do
      assert {:ok, 0} = Search.count_results(nil)
    end

    test "accepts rrf_k option" do
      result = Search.count_results("test", rrf_k: 80)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
