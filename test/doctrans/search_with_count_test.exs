defmodule Doctrans.SearchWithCountTest do
  @moduledoc """
  Covers `Doctrans.Search.search_with_count/2`: one embedding per query, a
  total that describes every match rather than the page it ships with, and the
  retrieval mode it reports -- which is how a caller tells an embedding outage
  apart from a query that simply matched nothing.

  Not async: each test swaps `:embedding_module` in the global `Application`
  environment, as every other module in this suite that does so.
  """
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.Pages
  alias Doctrans.Repo
  alias Doctrans.Search

  alias Doctrans.Search.{
    EmbeddingDimensionStub,
    EmbeddingErrorStub,
    EmbeddingNilStub,
    EmbeddingProbe
  }

  alias Doctrans.TestEnv

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  describe "search_with_count/2" do
    test "counts and lists matches from a single query embedding" do
      page = searchable_page("A page about sharedembeddingterm and nothing else")

      TestEnv.put_env(:embedding_probe_pid, self())
      use_embedding_module(EmbeddingProbe)

      assert {:ok, %{results: [result], total_count: 1, retrieval: :hybrid}} =
               Search.search_with_count("sharedembeddingterm")

      assert result.page_id == page.id
      assert result.snippet =~ "sharedembeddingterm"

      # One inference call is what makes the count and the results describe the
      # same vector: there is no second embedding for them to disagree about.
      assert_received {:embedded, "sharedembeddingterm"}
      refute_received {:embedded, "sharedembeddingterm"}
    end

    test "counts every match, not just the page of results returned" do
      # Seven matches against a limit of five: a total that merely described the
      # returned page would read 5, and pagination would lose the last two.
      for index <- 1..7 do
        searchable_page("Page #{index} about countbeyondlimitterm", "Counted Doc #{index}")
      end

      assert {:ok, %{results: results, total_count: total_count}} =
               Search.search_with_count("countbeyondlimitterm", limit: 5)

      assert length(results) == 5
      assert total_count == 7
    end

    test "counts every match from the last page of results too" do
      for index <- 1..7 do
        searchable_page("Page #{index} about offsetcountterm", "Offset Doc #{index}")
      end

      assert {:ok, %{results: results, total_count: total_count}} =
               Search.search_with_count("offsetcountterm", limit: 5, offset: 5)

      # The tail page is short, but the total still describes the whole match set.
      assert length(results) == 2
      assert total_count == 7
    end

    test "returns a tagged error when the search statement fails" do
      "A page about dbfailureterm"
      |> searchable_page()
      |> embed()

      use_embedding_module(EmbeddingDimensionStub)

      log =
        capture_log(fn ->
          assert {:error, {:database_error, _}} = Search.search_with_count("dbfailureterm")
        end)

      assert log =~ "Hybrid search query failed"
    end
  end

  describe "retrieval without an embedding server" do
    test "still returns the keyword matches, flagged as keyword-only" do
      page = searchable_page("A page about failingembeddingterm and nothing else")

      # An indexed page the query does not mention. It is what proves the
      # semantic half really sat out: ranked against a NULL vector it would
      # otherwise place first and count as a match nobody searched for.
      "An indexed page about something unrelated"
      |> searchable_page("Indexed Doc")
      |> embed()

      fail_embeddings_for("failingembeddingterm")

      log =
        capture_log(fn ->
          assert {:ok, %{results: [result], total_count: 1, retrieval: :keyword_only}} =
                   Search.search_with_count("failingembeddingterm")

          # The whole point of degrading: the full-text index already knows this
          # page, and an unreachable embedding server cannot make it forget.
          assert result.page_id == page.id
          assert result.snippet =~ "failingembeddingterm"
        end)

      # An outage only stays diagnosable if the reason reaches the log; nothing
      # else in the response says why the ranking was half of one.
      assert log =~ "keyword-only"
      assert log =~ ":timeout"
      assert_received {:embedding_call, "failingembeddingterm"}
    end

    test "reports no matches as no matches, not as an outage" do
      searchable_page("A page about somethingelseentirely")

      fail_embeddings_for("unmatchedkeywordterm")

      capture_log(fn ->
        assert {:ok, %{results: [], total_count: 0, retrieval: :keyword_only}} =
                 Search.search_with_count("unmatchedkeywordterm")
      end)
    end

    test "counts every degraded match, not just the page returned" do
      for index <- 1..7 do
        searchable_page("Page #{index} about degradedcountterm", "Degraded Doc #{index}")
      end

      fail_embeddings_for("degradedcountterm")

      capture_log(fn ->
        assert {:ok, %{results: results, total_count: 7, retrieval: :keyword_only}} =
                 Search.search_with_count("degradedcountterm", limit: 5)

        assert length(results) == 5
      end)
    end

    test "counts and returns degraded matches past the fused-score floor" do
      # 45 > the 40 the floor admits: keyword-only fuses one rank, so the score
      # is 1/(60 + fts_rank), which crosses under 0.01 at rank 41. Applying the
      # hybrid floor here would cap both the page and its total at 40 and call
      # that the whole match set.
      for index <- 1..45 do
        searchable_page("Page #{index} about floorcapterm", "Floor Cap Doc #{index}")
      end

      fail_embeddings_for("floorcapterm")

      capture_log(fn ->
        assert {:ok, %{results: results, total_count: 45, retrieval: :keyword_only}} =
                 Search.search_with_count("floorcapterm", limit: 50)

        assert length(results) == 45
      end)
    end

    test "pages through degraded matches past the floor rather than ending at it" do
      for index <- 1..45 do
        searchable_page("Page #{index} about floorpageterm", "Floor Page Doc #{index}")
      end

      fail_embeddings_for("floorpageterm")

      capture_log(fn ->
        assert {:ok, %{results: results, total_count: 45, retrieval: :keyword_only}} =
                 Search.search_with_count("floorpageterm", limit: 20, offset: 40)

        # The tail the floor used to swallow whole.
        assert length(results) == 5
      end)
    end

    test "reports a vectorless embedding success as keyword-only, not as hybrid" do
      page = searchable_page("A page about nilvectorterm and nothing else")

      # `{:ok, nil}` is a legal embedding result; ranking never ran, so calling
      # it hybrid would claim a semantic half that sat out.
      use_embedding_module(EmbeddingNilStub)

      capture_log(fn ->
        assert {:ok, %{results: [result], total_count: 1, retrieval: :keyword_only}} =
                 Search.search_with_count("nilvectorterm")

        assert result.page_id == page.id
      end)
    end

    test "still rejects bounds Postgres cannot encode" do
      fail_embeddings_for("boundedegradeterm")

      # Degrading is about the ranking, not about what reaches Postgres: an
      # unencodable offset must still be refused rather than raised.
      assert {:error, {:invalid_search_bounds, [offset: _]}} =
               Search.search_with_count("boundedegradeterm", offset: 99_999_999_999_999_999_999)

      refute_received {:embedding_call, _}
    end
  end

  describe "pagination past the end" do
    test "reports no matches rather than a total it cannot see" do
      for index <- 1..3 do
        searchable_page("Page #{index} about pastendterm", "Past End Doc #{index}")
      end

      # Documented behaviour: the total is a window over the returned rows, so
      # an offset beyond the last match has nothing to count.
      assert {:ok, %{results: [], total_count: 0}} =
               Search.search_with_count("pastendterm", limit: 5, offset: 50)
    end
  end

  defp searchable_page(text, title \\ "Search With Count Doc") do
    document = document_fixture(%{status: "completed", title: title})
    page = page_fixture(document, %{page_number: 1})

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: text
      })

    page
  end

  # The statement only compares vectors for pages that have one, so a page must
  # be indexed before a width mismatch can reach Postgres at all.
  defp embed(page) do
    page
    |> Ecto.Changeset.change(embedding: Pgvector.new(List.duplicate(0.1, 1024)))
    |> Repo.update!()
  end

  defp use_embedding_module(module), do: TestEnv.put_env(:embedding_module, module)

  # The plan fails this query alone, so the swapped-in module stays
  # behaviourally identical for anything else embedding concurrently.
  defp fail_embeddings_for(query) do
    use_embedding_module(EmbeddingErrorStub)
    TestEnv.put_env(:embedding_error_plan, [{query, :timeout}])
    TestEnv.put_env(:embedding_call_observer, self())
  end
end
