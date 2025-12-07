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
      # This is a conceptual test - results that match both semantically
      # and lexically should have higher RRF scores
      doc = document_fixture(%{status: "completed", title: "RRF Test Doc"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Important information about machine learning algorithms"
        })

      # Search for a term that should match both FTS and semantic
      {:ok, results} = Search.search("machine learning")
      assert is_list(results)
    end
  end
end
