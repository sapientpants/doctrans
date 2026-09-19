defmodule DoctransWeb.SearchLiveTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures
  import Phoenix.LiveViewTest

  alias Doctrans.Documents

  # Search runs off the LiveView process now, so assertions on results await it.
  @async_timeout 2_000

  # Mirrors `DoctransWeb.SearchLive`'s page size. A corpus is sized against it so
  # the split between page 1 and page 2 is a property of the fixture, not a
  # coincidence of how many documents a test happened to create.
  @per_page 20

  describe "Search LiveView" do
    test "shows validation errors in the selected locale", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?lang=de")

      view
      |> element("#search-form")
      |> render_submit(%{q: String.duplicate("a", 501)})

      assert has_element?(view, "#flash-error", "Suchanfrage zu lang (maximal 500 Zeichen)")
    end

    test "mounts with empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "h1", "Search")
      assert has_element?(view, "#search-form")
      assert has_element?(view, "#search-input")
      assert has_element?(view, "#search-prompt")
    end

    test "assigns default values on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "#search-input[value='']")
      assert has_element?(view, "#search-prompt")
      refute has_element?(view, "#search-loading")
      refute has_element?(view, "#search-empty")
    end

    test "shows back button to index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "a[href='/']")
    end

    test "displays initial search prompt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert render(view) =~ "Enter a search term to find content across all your documents"
    end

    test "submits search via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      # Submit search, it will push_patch to /search?q=test
      view |> element("#search-form") |> render_submit(%{q: "test"})

      # The search runs asynchronously, so await it before asserting on results
      render_async(view, @async_timeout)
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-loading")
      refute has_element?(view, "#search-error")
    end

    test "shows no results message when search returns empty", %{conn: conn} do
      # A library with content in it, none of which answers this query: the empty
      # state has to mean "nothing matched", not "nothing was searched".
      ranked_corpus("presentterm", 2, "Present Doc")

      # No assertion on the loading state here: nothing holds the search open,
      # so the search can answer before the first render is inspected. The async
      # suite parks the embedding stub on a barrier and pins that state
      # deterministically; what this test is for is the empty *outcome*.
      {:ok, view, _html} = live(conn, ~p"/search?q=nonexistent")

      render_async(view, @async_timeout)
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-results")
      refute has_element?(view, "#search-loading")
    end

    test "ignores empty search submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view |> element("#search-form") |> render_submit(%{q: "   "})

      # Should stay on initial state
      assert has_element?(view, "#search-prompt")
    end

    test "trims whitespace from search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view |> element("#search-form") |> render_submit(%{q: "  test query  "})

      # Should patch with trimmed query (Phoenix uses + for spaces in URLs)
      assert_patch(view, ~p"/search?q=test+query")

      # Let the search the patch started finish before the test tears down
      render_async(view, @async_timeout)
    end

    test "renders every match, in the order the search ranked them", %{conn: conn} do
      [first, second, third] = ranked_corpus("orderedterm", 3, "Ordered Doc")

      {:ok, view, _html} = live(conn, ~p"/search?q=orderedterm")

      # Wait for the asynchronous search to complete
      render_async(view, @async_timeout)

      assert has_element?(view, "#search-results")

      # The cards are the match set, in rank order -- not a set of ids that
      # happen to be on the page in whatever order they arrived.
      assert rendered_result_ids(view) == [first.id, second.id, third.id]

      assert summary(view) == ~s(Showing 1-3 of 3 results for "orderedterm")
      refute has_element?(view, "#search-empty")
      refute has_element?(view, "#search-pagination")
    end

    test "does not warn about degraded retrieval on a healthy search", %{conn: conn} do
      [page] = ranked_corpus("healthyterm", 1, "Healthy Doc")

      {:ok, view, _html} = live(conn, ~p"/search?q=healthyterm")

      render_async(view, @async_timeout)

      # Semantic search ran, so the results are the whole answer and the page
      # must not hedge about them.
      assert has_element?(view, "#search-result-#{page.id}")
      refute has_element?(view, "#search-degraded")
    end

    test "does not warn about degraded retrieval when a healthy search finds nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/search?q=nothingmatchesthis")

      render_async(view, @async_timeout)

      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-degraded")
    end

    test "keeps the submitted query in the search box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=myquery")
      render_async(view, @async_timeout)

      assert has_element?(view, "#search-input[value='myquery']")
    end

    test "a result links to its own page, carrying the search behind it", %{conn: conn} do
      doc = document_fixture(%{title: "Link Test Doc", status: "completed"})
      page = page_fixture(doc, %{page_number: 7})

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "LinkableContent unique"
        })

      {:ok, _page} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "LinkableContent translated"
        })

      {:ok, view, _html} = live(conn, ~p"/search?q=LinkableContent")

      render_async(view, @async_timeout)

      # Every part of this link is load-bearing: the document and the page
      # number are where the match actually is, and `q` plus `search_page` are
      # what let the reader come back to the results they left.
      assert result_href(view, page) ==
               "/documents/#{doc.id}?page=7&from=search&q=LinkableContent&search_page=1"
    end

    test "back link navigates to home", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view
      |> element("a[data-phx-link=\"redirect\"]")
      |> render_click()

      assert_redirect(view, "/")
    end

    test "handles empty query parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=")

      # Should show initial state
      assert has_element?(view, "#search-prompt")
      refute has_element?(view, "#search-empty")
    end

    test "handles search with special characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=test%2Bquery")

      render_async(view, @async_timeout)

      # Nothing matches, but the query must not fail the search either.
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-error")
    end

    test "pages through a match set larger than one page", %{conn: conn} do
      pages = ranked_corpus("pagedterm", 25, "Paged Doc")
      {first_page, second_page} = Enum.split(pages, @per_page)

      {:ok, view, _html} = live(conn, ~p"/search?q=pagedterm")

      render_async(view, @async_timeout)

      # 25 matches against 20 per page: the summary has to describe the whole
      # match set, not the page, or the second page never becomes reachable.
      assert rendered_result_ids(view) == Enum.map(first_page, & &1.id)
      assert summary(view) == ~s(Showing 1-20 of 25 results for "pagedterm")
      assert has_element?(view, "#search-pagination")
      refute has_element?(view, "#search-pagination a[href*='page=0']")

      # Reachable, not merely addressable: the Next control is what takes the
      # reader to the rest of the matches.
      view |> element("#search-pagination a[href*='page=2']") |> render_click()
      assert_patch(view, ~p"/search?q=pagedterm&page=2")
      render_async(view, @async_timeout)

      # Page 2 is exactly the matches page 1 did not show, still in rank order.
      assert rendered_result_ids(view) == Enum.map(second_page, & &1.id)
      assert summary(view) == ~s(Showing 21-25 of 25 results for "pagedterm")
      assert has_element?(view, "#search-pagination a[href*='page=1']")
    end

    test "a page parameter lands on that page of the match set", %{conn: conn} do
      pages = ranked_corpus("directpageterm", 25, "Direct Page Doc")
      [first_of_page_two | _] = tail = Enum.drop(pages, @per_page)

      {:ok, view, _html} = live(conn, ~p"/search?q=directpageterm&page=2")

      render_async(view, @async_timeout)

      assert rendered_result_ids(view) == Enum.map(tail, & &1.id)
      assert summary(view) == ~s(Showing 21-25 of 25 results for "directpageterm")

      # A result opened from page 2 has to remember it was page 2, or Back
      # lands the reader on results they already scrolled past.
      assert result_href(view, first_of_page_two) ==
               "/documents/#{first_of_page_two.document_id}?page=21&from=search" <>
                 "&q=directpageterm&search_page=2"
    end

    test "an unparseable page parameter falls back to the first page of matches", %{conn: conn} do
      pages = ranked_corpus("invalidpageterm", 3, "Invalid Page Doc")

      {:ok, view, _html} = live(conn, ~p"/search?q=invalidpageterm&page=invalid")

      render_async(view, @async_timeout)

      # Falling back means page 1 of a real match set, not an empty page: a
      # fallback that skipped the results would look identical to a library
      # with nothing in it.
      assert rendered_result_ids(view) == Enum.map(pages, & &1.id)
      assert summary(view) == ~s(Showing 1-3 of 3 results for "invalidpageterm")
      refute has_element?(view, "#search-error")
    end

    test "clamps a page parameter too large to be an offset", %{conn: conn} do
      # Unclamped, this overflows bigint, Postgrex raises rather than returning
      # an error, and the user gets "Search unavailable" for what is really just
      # a page past the end of the results.
      {:ok, view, _html} = live(conn, ~p"/search?q=test&page=99999999999999999999")

      render_async(view, @async_timeout)
      refute has_element?(view, "#search-error")
      assert has_element?(view, "#search-empty")
    end
  end

  # A match set whose ranking is fixed rather than incidental: each page repeats
  # the term one time less than the page before it, so the full-text half ranks
  # them strictly and the list returned here is the order the search owes back --
  # highest first. Nothing else in the corpus mentions the term.
  defp ranked_corpus(term, count, title_prefix) do
    for rank <- 1..count do
      document = document_fixture(%{title: "#{title_prefix} #{rank}", status: "completed"})
      page = page_fixture(document, %{page_number: rank})

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown:
            String.duplicate("#{term} ", count + 1 - rank) <> "and some filler text"
        })

      page
    end
  end

  # The page ids of the rendered result cards, in the order the page lists them.
  defp rendered_result_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#search-results a[id^='search-result-']")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "search-result-", ""))
  end

  defp result_href(view, page) do
    view
    |> element("#search-result-#{page.id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp summary(view) do
    view
    |> element("#search-summary")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
