defmodule Doctrans.SearchTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.Page
  alias Doctrans.Documents.Pages
  alias Doctrans.Repo
  alias Doctrans.Search

  import Doctrans.Fixtures

  # The RRF constant `search/2` uses when the caller names none. Scores are
  # asserted against it rather than against "something positive", because
  # 1/(k + rank) is the whole of what a fused score means.
  @default_rrf_k 60

  # The stub every test in this module embeds with returns this vector for any
  # text, so a page carrying it is a perfect semantic match for any query.
  defp query_aligned_embedding, do: Pgvector.new(List.duplicate(0.1, 1024))

  # Half the dimensions zeroed: cosine similarity 0.707 against the vector
  # above -- clear of the 0.55 floor the semantic half applies, and strictly
  # below a page that carries the query's own vector.
  defp half_aligned_embedding do
    Pgvector.new(List.duplicate(0.1, 512) ++ List.duplicate(0.0, 512))
  end

  describe "search/2" do
    test "returns empty list for empty query" do
      assert {:ok, []} = Search.search("")
    end

    test "returns empty list for nil query" do
      assert {:ok, []} = Search.search(nil)
    end

    test "returns no matches when nothing in the library answers the query" do
      # A completed, indexed page that simply says something else: the empty
      # answer has to come from the ranking, not from an empty library.
      searchable_page("A page about gardening tools", "Unrelated Doc")

      assert {:ok, []} = Search.search("nothinginthelibrarysaysthis")
    end

    test "finds a page by a keyword in its original markdown" do
      document = document_fixture(%{status: "completed", title: "Keyword Test Doc"})
      page = page_fixture(document, %{page_number: 3})

      {:ok, page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "This is searchable content about cats and dogs"
        })

      assert {:ok, [result]} = Search.search("cats")
      assert result.page_id == page.id
      assert result.document_id == document.id
      assert result.document_title == "Keyword Test Doc"
      assert result.page_number == 3
      assert result.snippet =~ "cats"
    end

    test "finds a page by a keyword in its translated markdown" do
      document = document_fixture(%{status: "completed", title: "Translated Test Doc"})
      page = page_fixture(document, %{page_number: 2})

      {:ok, page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Original content"
        })

      {:ok, page} =
        Pages.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Translated content about elephants"
        })

      assert {:ok, [result]} = Search.search("elephants")
      assert result.page_id == page.id
      assert result.page_number == 2
      assert result.snippet =~ "elephants"
    end

    test "FTS applies stemming - 'running' matches 'run'" do
      document = document_fixture(%{status: "completed", title: "Stemming Test"})
      page = page_fixture(document, %{page_number: 1})

      {:ok, page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "placeholder"
        })

      {:ok, page} =
        Pages.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "The runner was running fast through the field"
        })

      # "run" should match "running" and "runner" due to English stemming
      assert {:ok, [result]} = Search.search("run")
      assert result.page_id == page.id
    end

    test "describes a match by page, document, rank and snippet" do
      document = document_fixture(%{status: "completed", title: "Structure Test"})
      page = page_fixture(document, %{page_number: 5})

      {:ok, page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Unique searchterm findme content"
        })

      assert {:ok, [result]} = Search.search("findme")

      # The only ranking that ran is the full-text one, and this is its first
      # rank -- so the fused score is exactly one reciprocal rank.
      assert result == %{
               page_id: page.id,
               document_id: document.id,
               document_title: "Structure Test",
               page_number: 5,
               image_path: page.image_path,
               score: 1 / (@default_rrf_k + 1),
               snippet: "Unique searchterm findme content"
             }
    end

    test "ranks the whole match set, best match first" do
      [first, second, third, fourth] = ranked_corpus("rankedterm", 4)

      assert {:ok, results} = Search.search("rankedterm")

      # The order is the answer, not an accident of how the rows came back:
      # each page mentions the term once less than the page before it.
      assert Enum.map(results, & &1.page_id) == [first.id, second.id, third.id, fourth.id]
      assert Enum.map(results, & &1.page_number) == [1, 2, 3, 4]

      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      assert Enum.uniq(scores) == scores
    end

    test "breaks a fused-score tie by page id" do
      # One match from each half, both at rank 1, so both score 1/(k + 1) and
      # only the tie-break can order them. Created first, so its time-ordered
      # UUID is the lower of the two.
      semantic_only = embedded_page("nothing lexical in common here", query_aligned_embedding())
      keyword_only = searchable_page("a page about tiebreakterm only", "Tie Keyword Doc")

      assert semantic_only.id < keyword_only.id

      assert {:ok, [first, second]} = Search.search("tiebreakterm")

      assert first.score == second.score
      assert [first.page_id, second.page_id] == [semantic_only.id, keyword_only.id]
    end

    test "limit returns the top-ranked matches only" do
      [first, second, _third, _fourth] = ranked_corpus("limitedterm", 4)

      assert {:ok, results} = Search.search("limitedterm", limit: 2)
      assert Enum.map(results, & &1.page_id) == [first.id, second.id]
    end

    test "offset pages past the matches already returned" do
      [_first, _second, third, fourth] = ranked_corpus("offsetterm", 4)

      assert {:ok, results} = Search.search("offsetterm", limit: 2, offset: 2)
      assert Enum.map(results, & &1.page_id) == [third.id, fourth.id]
    end

    test "limit and offset together walk the match set without repeating or dropping one" do
      pages = ranked_corpus("combinedterm", 5)

      walked =
        Enum.flat_map(0..4//2, fn offset ->
          assert {:ok, results} = Search.search("combinedterm", limit: 2, offset: offset)
          Enum.map(results, & &1.page_id)
        end)

      assert walked == Enum.map(pages, & &1.id)
    end

    test "rrf_k smooths the fused score without changing the ranking" do
      [first, second] = ranked_corpus("smoothedterm", 2)

      assert {:ok, [default_top, default_next]} = Search.search("smoothedterm")
      assert {:ok, [smoothed_top, smoothed_next]} = Search.search("smoothedterm", rrf_k: 100)

      assert [default_top.page_id, default_next.page_id] == [first.id, second.id]
      assert [smoothed_top.page_id, smoothed_next.page_id] == [first.id, second.id]

      # A larger k is a flatter curve: the same two ranks, closer together.
      assert default_top.score == 1 / (@default_rrf_k + 1)
      assert smoothed_top.score == 1 / 101
      assert smoothed_top.score - smoothed_next.score < default_top.score - default_next.score
    end

    test "returns empty list when document not completed" do
      document = document_fixture(%{status: "processing", title: "Incomplete Doc"})
      page = page_fixture(document, %{page_number: 1})

      {:ok, _page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Content with uniqueword99"
        })

      # Should not find anything because document status is "processing"
      assert {:ok, []} = Search.search("uniqueword99")
    end

    test "returns empty list when page extraction not completed" do
      document = document_fixture(%{status: "completed", title: "Test Doc"})
      _page = page_fixture(document, %{page_number: 1})

      # Page is created with pending extraction status
      assert {:ok, []} = Search.search("anything")
    end

    test "RRF ranks a page both halves found above a page only one half found" do
      # A page the keyword index and the semantic index both rank first, against
      # one match from each half alone. Two reciprocal ranks beat one, which is
      # the whole point of fusing them.
      both =
        embedded_page("a page about fusedterm and more fusedterm", query_aligned_embedding())

      keyword_only = searchable_page("another page about fusedterm", "Fused Keyword Doc")
      semantic_only = embedded_page("nothing lexical in common", half_aligned_embedding())

      assert {:ok, [top | rest]} = Search.search("fusedterm")

      assert top.page_id == both.id
      assert top.score == 1 / (@default_rrf_k + 1) + 1 / (@default_rrf_k + 1)

      # Both runners-up hold one rank-2 reciprocal, so they tie; what matters
      # here is that neither reaches the fused page.
      assert Enum.sort(Enum.map(rest, & &1.page_id)) ==
               Enum.sort([keyword_only.id, semantic_only.id])

      assert Enum.all?(rest, &(&1.score == 1 / (@default_rrf_k + 2)))
    end
  end

  describe "search_in_document/3" do
    test "returns empty list for empty query" do
      document = document_fixture(%{status: "completed"})
      assert {:ok, []} = Search.search_in_document(document.id, "")
    end

    test "returns empty list for nil query" do
      document = document_fixture(%{status: "completed"})
      assert {:ok, []} = Search.search_in_document(document.id, nil)
    end

    test "limit caps the pages returned" do
      document = document_fixture(%{status: "completed"})

      for page_number <- 1..3 do
        insert_indexed_page(document, page_number, query_aligned_embedding())
      end

      assert {:ok, results} = Search.search_in_document(document.id, "test", limit: 2)
      assert length(results) == 2
    end

    test "min_similarity excludes pages the query is only loosely related to" do
      document = document_fixture(%{status: "completed"})
      aligned = insert_indexed_page(document, 1, query_aligned_embedding())
      loose = insert_indexed_page(document, 2, half_aligned_embedding())

      # The default floor admits both, most similar first.
      assert {:ok, results} = Search.search_in_document(document.id, "test")
      assert Enum.map(results, & &1.page_id) == [aligned.id, loose.id]

      # Raised past the loose page's 0.707, it is the only one left.
      assert {:ok, [only]} = Search.search_in_document(document.id, "test", min_similarity: 0.9)
      assert only.page_id == aligned.id
    end

    test "only searches within specified document" do
      document = document_fixture(%{status: "completed", title: "Doc One"})
      other = document_fixture(%{status: "completed", title: "Doc Two"})

      page = insert_indexed_page(document, 1, query_aligned_embedding())
      _other_page = insert_indexed_page(other, 1, query_aligned_embedding())

      assert {:ok, results} = Search.search_in_document(document.id, "content")
      assert Enum.map(results, & &1.page_id) == [page.id]
    end

    test "returns the page text and its similarity to the query" do
      document = document_fixture(%{status: "completed"})
      page = insert_indexed_page(document, 4, query_aligned_embedding())

      assert {:ok, [result]} = Search.search_in_document(document.id, "test")

      assert result.page_id == page.id
      assert result.page_number == 4
      assert result.original_markdown == page.original_markdown
      assert result.translated_markdown == page.translated_markdown
      assert result.content_revision == page.content_revision
      assert_in_delta result.similarity, 1.0, 1.0e-6
    end
  end

  describe "search_with_count/2" do
    test "returns empty results and a zero count for an empty query" do
      assert {:ok, %{results: [], total_count: 0, retrieval: :hybrid}} =
               Search.search_with_count("")
    end

    test "returns empty results and a zero count for a nil query" do
      assert {:ok, %{results: [], total_count: 0, retrieval: :hybrid}} =
               Search.search_with_count(nil)
    end

    # An unasked query skipped no ranking, so it reports the healthy mode: only
    # a search that could not be embedded is `:keyword_only`.
    #
    # The cases that swap `:embedding_module` globally live in
    # `Doctrans.SearchWithCountTest`, which is `async: false`; this module is not.
  end

  # Postgrex raises on a value it cannot encode, which would escape the
  # `{:ok, _} | {:error, _}` contract and kill the caller rather than fail the
  # search. Every entry point has to reject those bounds before Postgres sees
  # them -- including `search/2`, which shares the statement.
  describe "query bounds" do
    test "rejects an offset too large for Postgres to encode" do
      assert {:error, {:invalid_search_bounds, [offset: _]}} =
               Search.search_with_count("test", offset: 99_999_999_999_999_999_999)
    end

    test "rejects a limit too large for Postgres to encode" do
      assert {:error, {:invalid_search_bounds, [limit: _]}} =
               Search.search_with_count("test", limit: 99_999_999_999_999_999_999)
    end

    test "rejects a non-integer rrf_k" do
      assert {:error, {:invalid_search_bounds, [rrf_k: _]}} =
               Search.search_with_count("test", rrf_k: 60.0)
    end

    test "rejects a negative offset" do
      assert {:error, {:invalid_search_bounds, [offset: -1]}} =
               Search.search_with_count("test", offset: -1)
    end

    test "rejects out-of-range bounds through search/2 as well" do
      assert {:error, {:invalid_search_bounds, [offset: _]}} =
               Search.search("test", offset: 99_999_999_999_999_999_999)
    end

    test "accepts the largest offset Postgres can encode" do
      assert {:ok, %{results: [], total_count: 0, retrieval: :hybrid}} =
               Search.search_with_count("test", offset: 9_223_372_036_854_775_807)
    end
  end

  # A match set whose ranking is fixed rather than incidental: each page repeats
  # the term one time less than the page before it, so the full-text half ranks
  # them strictly. Returned in the order the search owes them back, and each
  # page's number is its rank, so an assertion can name either.
  defp ranked_corpus(term, count) do
    for rank <- 1..count do
      text = String.duplicate("#{term} ", count + 1 - rank) <> "and some filler text"
      indexed_page("Ranked Doc #{rank}", rank, text)
    end
  end

  defp searchable_page(text, title), do: indexed_page(title, 1, text)

  # One completed, extracted page in a completed document of its own: the
  # smallest thing global search is allowed to find.
  defp indexed_page(title, page_number, markdown) do
    document = document_fixture(%{status: "completed", title: title})

    {:ok, page} =
      document
      |> page_fixture(%{page_number: page_number})
      |> Pages.update_page_extraction(%{
        extraction_status: "completed",
        original_markdown: markdown
      })

    page
  end

  # A page the semantic half can rank: indexed with a vector of this module's
  # choosing, so its similarity to the stubbed query embedding is arithmetic
  # rather than a property of any model.
  defp embedded_page(text, embedding) do
    text
    |> searchable_page("Embedded Doc")
    |> Ecto.Changeset.change(embedding: embedding)
    |> Repo.update!()
  end

  # Inserted through `Repo` rather than the `Pages` API to pin the embedding
  # alongside the text in one write.
  defp insert_indexed_page(document, page_number, embedding) do
    Repo.insert!(%Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: page_number,
      image_path: "documents/#{document.id}/pages/page_#{page_number}.png",
      original_markdown: "Content in document #{document.title} page #{page_number}",
      translated_markdown: "Translated content page #{page_number}",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: embedding
    })
  end
end
