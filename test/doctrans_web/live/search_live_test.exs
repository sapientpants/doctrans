defmodule DoctransWeb.SearchLiveTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures
  import Phoenix.LiveViewTest

  alias Doctrans.Documents

  # Search runs off the LiveView process now, so assertions on results await it.
  @async_timeout 2_000

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
      assert render(view) =~ "Search documents"
    end

    test "assigns default values on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      # Check default assigns
      assert view |> element("#search-input") |> render() =~ ""
      assert render(view) =~ "Enter a search term to find content across all your documents."
      refute render(view) =~ "Searching..."
      refute render(view) =~ "No results found"
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
      {:ok, view, _html} = live(conn, ~p"/search?q=nonexistent")

      assert has_element?(view, "#search-loading")

      render_async(view, @async_timeout)
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-loading")
    end

    test "ignores empty search submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view |> element("#search-form") |> render_submit(%{q: "   "})

      # Should stay on initial state
      assert render(view) =~ "Search documents"
    end

    test "trims whitespace from search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view |> element("#search-form") |> render_submit(%{q: "  test query  "})

      # Should patch with trimmed query (Phoenix uses + for spaces in URLs)
      assert_patch(view, ~p"/search?q=test+query")

      # Let the search the patch started finish before the test tears down
      render_async(view, @async_timeout)
    end

    test "shows results when matching documents exist", %{conn: conn} do
      # Create a completed document with completed page containing searchable content
      doc = document_fixture(%{title: "Searchable Doc", status: "completed"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "This is unique searchterm content"
        })

      {:ok, _page} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "This is unique searchterm translated"
        })

      {:ok, view, _html} = live(conn, ~p"/search?q=searchterm")

      # Wait for the asynchronous search to complete
      render_async(view, @async_timeout)

      assert has_element?(view, "#search-results")
      assert has_element?(view, "#search-result-#{page.id}")
      assert has_element?(view, "#search-summary")
      refute has_element?(view, "#search-empty")
    end

    test "does not warn about degraded retrieval on a healthy search", %{conn: conn} do
      doc = document_fixture(%{title: "Healthy Doc", status: "completed"})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, _page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "This is healthyterm content"
        })

      {:ok, view, _html} = live(conn, ~p"/search?q=healthyterm")

      render_async(view, @async_timeout)

      # Semantic search ran, so the results are the whole answer and the page
      # must not hedge about them.
      assert has_element?(view, "#search-results")
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

    test "search results link to document pages", %{conn: conn} do
      # Create completed document with searchable content
      doc = document_fixture(%{title: "Link Test Doc", status: "completed"})
      page = page_fixture(doc, %{page_number: 1})

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

      # The card links back into the document, carrying the search it came from
      # so the reader can return to these results.
      assert has_element?(view, "#search-result-#{page.id}")

      href =
        view
        |> element("#search-result-#{page.id}")
        |> render()

      assert href =~ doc.id
      assert href =~ "from=search"
      assert href =~ "q=LinkableContent"
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
      assert render(view) =~ "Search documents"
      refute render(view) =~ "No results found"
    end

    test "handles search with special characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=test%2Bquery")

      render_async(view, @async_timeout)

      # Nothing matches, but the query must not fail the search either.
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-error")
    end

    test "shows pagination controls when there are results", %{conn: conn} do
      # Create multiple documents to potentially trigger pagination
      Enum.each(1..25, fn i ->
        doc = document_fixture(%{title: "Test Doc #{i}", status: "completed"})
        page = page_fixture(doc, %{page_number: 1})

        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Content #{i}"
        })

        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Content #{i}"
        })
      end)

      {:ok, view, _html} = live(conn, ~p"/search?q=Content")

      render_async(view, @async_timeout)

      # 25 matches against 20 per page: the total has to describe the whole match
      # set, not the page, or the second page never becomes reachable.
      assert has_element?(view, "#search-results")
      assert has_element?(view, "#search-pagination")
      assert has_element?(view, "#search-summary", "of 25 results")
    end

    test "handles page parameter correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=test&page=2")

      render_async(view, @async_timeout)
      assert has_element?(view, "#search-empty")
      refute has_element?(view, "#search-error")
    end

    test "handles invalid page parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=test&page=invalid")

      render_async(view, @async_timeout)
      assert has_element?(view, "#search-empty")
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
end
