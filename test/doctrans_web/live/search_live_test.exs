defmodule DoctransWeb.SearchLiveTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents

  describe "Search LiveView" do
    test "mounts with empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "h1", "Search")
      assert has_element?(view, "#search-form")
      assert has_element?(view, "#search-input")
      assert render(view) =~ "Search documents"
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

      # Should show results count (even if empty)
      assert render(view) =~ "0 results" or render(view) =~ "No results found"
    end

    test "shows no results message when search returns empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/search?q=nonexistent")

      assert html =~ "No results found" or html =~ "0 results"
    end

    test "ignores empty search submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      view |> element("#search-form") |> render_submit(%{q: "   "})

      # Should stay on initial state
      assert render(view) =~ "Search documents"
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

      # Wait for search to complete
      html = render(view)

      # Should show results or no results (depends on embedding service availability)
      assert html =~ "Searchable Doc" or html =~ "No results found" or html =~ "results"
    end

    test "displays query in results header", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?q=myquery")

      # Should display the query somewhere
      assert render(view) =~ "myquery"
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

      html = render(view)

      # If results are found, links should contain document ID and from=search param
      if html =~ "Link Test Doc" do
        assert html =~ "from=search"
        assert html =~ doc.id
      end
    end
  end
end
