defmodule Doctrans.Search.SemanticRelevanceTest do
  @moduledoc """
  Covers the similarity floor the semantic half of global search ranks behind,
  and the consequences of putting it there: an unrelated query
  can now come back empty, a keyword match is untouched by it, and the count
  describes the same filtered set the page is drawn from.

  Async: nothing here swaps the embedding module. `EmbeddingStub` answers every
  query with the same all-`0.1` vector, so the dial these tests turn is the
  *page* vector -- see `embedding_at/1`.
  """
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.Pages
  alias Doctrans.Repo
  alias Doctrans.Search

  import Doctrans.Fixtures

  # Comfortably under the 0.55 floor, and far enough under that a rounding
  # difference in Postgres cannot carry it over.
  @below 0.25

  # Comfortably over it.
  @above 0.75

  describe "the semantic floor" do
    test "an unrelated query returns nothing rather than the corpus in rank order" do
      page = searchable_page("Grundlagen der Bilanzanalyse und Kennzahlen")
      embed(page, @below)

      # Shares no lexeme with the page, so the full-text half cannot rescue it
      # and the semantic half is the only one that could answer.
      assert {:ok, result} = Search.search_with_count("Korallenriff")

      assert result.results == []
      assert result.total_count == 0
      assert result.retrieval == :hybrid
    end

    test "a semantic match above the floor is still found without any keyword match" do
      page = searchable_page("Grundlagen der Bilanzanalyse und Kennzahlen")
      embed(page, @above)

      assert {:ok, result} = Search.search_with_count("Korallenriff")

      assert [%{page_id: found}] = result.results
      assert found == page.id
      assert result.total_count == 1
    end

    test "a keyword match below the floor is untouched by it" do
      page = searchable_page("Liquiditaetssicherung im Familienunternehmen")
      embed(page, @below)

      # The floor gates which pages the semantic half may rank. A page that
      # cleared a tsquery match is the full-text half's row, and removing it
      # would be a recall loss the floor was never meant to cause.
      assert {:ok, result} = Search.search_with_count("Liquiditaetssicherung")

      assert [%{page_id: found}] = result.results
      assert found == page.id
      assert result.total_count == 1
    end

    test "the total counts the filtered set, not everything embedded" do
      document = completed_document("Mixed Library")

      above = for n <- 1..3, do: embed(indexed_page(document, n, "Seite #{n}"), @above)
      for n <- 4..8, do: embed(indexed_page(document, n, "Seite #{n}"), @below)

      assert {:ok, result} = Search.search_with_count("Korallenriff")

      assert result.total_count == 3
      assert MapSet.new(result.results, & &1.page_id) == MapSet.new(above, & &1.id)
    end

    test "pagination draws from the same filtered set the total describes" do
      document = completed_document("Paged Library")

      for n <- 1..3, do: embed(indexed_page(document, n, "Seite #{n}"), @above)
      for n <- 4..8, do: embed(indexed_page(document, n, "Seite #{n}"), @below)

      assert {:ok, first} = Search.search_with_count("Korallenriff", limit: 2)
      assert {:ok, rest} = Search.search_with_count("Korallenriff", limit: 2, offset: 2)

      assert length(first.results) == 2
      assert length(rest.results) == 1
      assert first.total_count == 3
      assert rest.total_count == 3

      # The page boundary must not lose or repeat a row: the two pages together
      # are exactly the match set the total claims.
      assert MapSet.size(MapSet.new(first.results ++ rest.results, & &1.page_id)) == 3
    end

    test "a semantic match set larger than 40 is ranked and counted in full" do
      document = completed_document("Deep Library")

      # 45 > the 40 a fused-score floor of 0.01 admits at k=60: the 41st rank
      # scores 1/101, under the floor, so restoring it drops five matches here
      # *and* shrinks the total to agree with the truncation.
      for n <- 1..45, do: embed(indexed_page(document, n, "Seite #{n}"), @above)

      assert {:ok, full} = Search.search_with_count("Korallenriff", limit: 50)
      assert {:ok, tail} = Search.search_with_count("Korallenriff", limit: 20, offset: 40)

      assert length(full.results) == 45
      assert full.total_count == 45
      assert length(tail.results) == 5
      assert tail.total_count == 45
    end
  end

  defp completed_document(title), do: document_fixture(%{status: "completed", title: title})

  defp searchable_page(text, title \\ "Semantic Relevance Doc") do
    indexed_page(completed_document(title), 1, text)
  end

  defp indexed_page(document, page_number, text) do
    page = page_fixture(document, %{page_number: page_number})

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: text
      })

    page
  end

  defp embed(page, similarity) do
    page
    |> Ecto.Changeset.change(embedding: embedding_at(similarity))
    |> Repo.update!()
  end

  # `EmbeddingStub` embeds every query as 1024 components of `0.1`. Against that
  # vector, a page vector built from `k` components of `+0.1` and the rest of
  # `-0.1` has cosine similarity exactly `(2k - 1024) / 1024`, because both
  # vectors have the same magnitude and the dot product counts agreements
  # against disagreements. Inverting that gives the `k` for a wanted similarity,
  # so a test can sit a page a chosen distance either side of the floor instead
  # of asserting against whatever an opaque fixture happened to produce.
  defp embedding_at(similarity) do
    dimensions = 1024
    positive = round(dimensions * (similarity + 1) / 2)

    Pgvector.new(List.duplicate(0.1, positive) ++ List.duplicate(-0.1, dimensions - positive))
  end
end
