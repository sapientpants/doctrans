defmodule Doctrans.SearchWithCountTest do
  @moduledoc """
  Covers `Doctrans.Search.search_with_count/2`: one embedding per query, and a
  total that describes every match rather than the page it ships with.

  Not async: each test swaps `:embedding_module` in the global `Application`
  environment, as every other module in this suite that does so.
  """
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.Pages
  alias Doctrans.Repo
  alias Doctrans.Search
  alias Doctrans.Search.{EmbeddingDimensionStub, EmbeddingErrorStub, EmbeddingProbe}
  alias Doctrans.TestEnv

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  describe "search_with_count/2" do
    test "counts and lists matches from a single query embedding" do
      page = searchable_page("A page about sharedembeddingterm and nothing else")

      TestEnv.put_env(:embedding_probe_pid, self())
      use_embedding_module(EmbeddingProbe)

      assert {:ok, %{results: results, total_count: total_count}} =
               Search.search_with_count("sharedembeddingterm")

      assert Enum.any?(results, &(&1.page_id == page.id))
      assert total_count == length(results)

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

    test "propagates an embedding failure" do
      # The plan fails this query alone, so the swapped-in module stays
      # behaviourally identical for anything else embedding concurrently.
      use_embedding_module(EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_plan, [{"failingembeddingterm", :timeout}])
      TestEnv.put_env(:embedding_call_observer, self())

      assert {:error, :timeout} = Search.search_with_count("failingembeddingterm")

      # The embedding is the first step for a reason: a query that cannot be
      # embedded must not reach the database at all.
      assert_received {:embedding_call, "failingembeddingterm"}
      refute_received {:embedding_call, _}
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
end
