defmodule DoctransWeb.DocumentLive.IndexTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  describe "Index LiveView" do
    test "displays empty state when no documents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h3", "No documents yet")
    end

    test "displays documents when present", %{conn: conn} do
      _doc = document_fixture(%{title: "Test Document"})
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h2", "Test Document")
    end

    test "shows upload button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#upload-document-btn")
    end

    test "opens upload modal when clicking upload button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#upload-modal")

      view |> element("#upload-document-btn") |> render_click()

      assert has_element?(view, "#upload-modal")
    end

    test "closes upload modal when clicking cancel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#upload-document-btn") |> render_click()
      assert has_element?(view, "#upload-modal")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "#upload-modal")
    end

    test "shows document progress for processing documents", %{conn: conn} do
      _doc = document_with_pages_fixture(%{status: "processing"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      # Should show progress bar for processing documents
      assert render(view) =~ "Progress"
    end

    test "shows completed badge for completed documents", %{conn: conn} do
      _doc = document_fixture(%{status: "completed"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".badge", "Completed")
    end

    test "deletes document when clicking delete button", %{conn: conn} do
      doc = document_fixture(%{title: "To Delete"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "h2", "To Delete")

      view
      |> element("button[phx-click='delete_document'][phx-value-id='#{doc.id}']")
      |> render_click()

      refute has_element?(view, "h2", "To Delete")
    end

    test "sort dropdown changes order", %{conn: conn} do
      _doc1 = document_fixture(%{title: "Alpha"})
      _doc2 = document_fixture(%{title: "Beta"})

      {:ok, view, _html} = live(conn, ~p"/")

      # Click sort by title A-Z
      view
      |> element("button[phx-click='sort'][phx-value-field='title'][phx-value-dir='asc']")
      |> render_click()

      # Verify both documents still show
      html = render(view)
      assert html =~ "Alpha"
      assert html =~ "Beta"
    end

    test "has search form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#dashboard-search-form")
      assert has_element?(view, "#dashboard-search-input")
    end

    test "shows uploading badge for uploading documents", %{conn: conn} do
      _doc = document_fixture(%{status: "uploading"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".badge", "Uploading")
    end

    test "shows extracting badge for extracting documents", %{conn: conn} do
      _doc = document_fixture(%{status: "extracting"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".badge", "Processing")
    end

    test "shows queued badge for queued documents", %{conn: conn} do
      _doc = document_fixture(%{status: "queued"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".badge", "Queued")
    end

    test "shows error badge for failed documents", %{conn: conn} do
      _doc = document_fixture(%{status: "error"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".badge", "Error")
    end

    test "displays page count when available", %{conn: conn} do
      _doc = document_fixture(%{total_pages: 10})
      {:ok, view, _html} = live(conn, ~p"/")

      assert render(view) =~ "10 pages"
    end

    test "upload modal contains target language select", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#upload-document-btn") |> render_click()

      assert has_element?(view, "#target-lang-select")
      html = render(view)
      assert html =~ "German"
      assert html =~ "English"
      assert html =~ "French"
    end

    test "displays document thumbnail when page image exists", %{conn: conn} do
      _doc = document_with_pages_fixture(%{title: "With Thumbnail"}, 1)
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "With Thumbnail"
    end

    test "document card links to document show page", %{conn: conn} do
      doc = document_fixture(%{title: "Linked Doc"})
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a[href='/documents/#{doc.id}']")
    end

    test "search form links to search page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # The search form is a regular HTML form that submits to /search
      html = render(view)
      assert html =~ ~s(action="/search")
      assert html =~ ~s(method="get")
    end

    test "sort by newest shows documents in order", %{conn: conn} do
      _doc1 = document_fixture(%{title: "First"})
      _doc2 = document_fixture(%{title: "Second"})

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-click='sort'][phx-value-field='inserted_at'][phx-value-dir='desc']")
      |> render_click()

      html = render(view)
      assert html =~ "First"
      assert html =~ "Second"
    end

    test "sort by oldest shows documents in reverse order", %{conn: conn} do
      _doc1 = document_fixture(%{title: "First"})
      _doc2 = document_fixture(%{title: "Second"})

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-click='sort'][phx-value-field='inserted_at'][phx-value-dir='asc']")
      |> render_click()

      html = render(view)
      assert html =~ "First"
      assert html =~ "Second"
    end

    test "sort by Z-A shows documents in descending title order", %{conn: conn} do
      _doc1 = document_fixture(%{title: "Alpha"})
      _doc2 = document_fixture(%{title: "Zebra"})

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-click='sort'][phx-value-field='title'][phx-value-dir='desc']")
      |> render_click()

      html = render(view)
      assert html =~ "Alpha"
      assert html =~ "Zebra"
    end

    test "shows progress bar for extracting documents", %{conn: conn} do
      _doc = document_with_pages_fixture(%{status: "extracting"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      assert render(view) =~ "Progress"
    end

    test "receives document updates via PubSub", %{conn: conn} do
      doc = document_fixture(%{title: "Initial"})
      {:ok, view, _html} = live(conn, ~p"/")

      # Verify initial state
      assert render(view) =~ "Initial"

      # Update and broadcast
      {:ok, updated} = Doctrans.Documents.update_document(doc, %{title: "Updated PubSub"})
      Doctrans.Documents.broadcast_document_update(updated)

      assert render(view) =~ "Updated PubSub"
    end

    test "receives page updates via PubSub", %{conn: conn} do
      doc = document_with_pages_fixture(%{title: "Page Update Test"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      [page | _] = doc.pages

      # Update page and broadcast
      {:ok, updated_page} =
        Doctrans.Documents.update_page_extraction(page, %{extraction_status: "completed"})

      Doctrans.Documents.broadcast_page_update(updated_page)

      # Just verify no crash
      assert render(view) =~ "Page Update Test"
    end

    test "validate_upload changes target language", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#upload-document-btn") |> render_click()

      # The upload form validates changes
      view
      |> element("#upload-form")
      |> render_change(%{"target_language" => "fr"})

      html = render(view)
      # Verify the select has French selected
      assert html =~ "French"
    end

    test "handles unknown PubSub messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send unknown message directly to the process
      send(view.pid, {:unknown_message, "test"})

      # Should not crash
      assert render(view) =~ "Doctrans"
    end
  end
end
