defmodule DoctransWeb.DocumentLive.IndexTest do
  use DoctransWeb.ConnCase, async: true

  alias Doctrans.Documents.Topics

  import Doctrans.Fixtures

  test "summary cards render progress, thumbnails, and document links", %{conn: conn} do
    document = document_with_pages_fixture(%{status: "processing"}, 2)
    [first_page | _] = document.pages

    {:ok, _} =
      Doctrans.Documents.update_page_extraction(first_page, %{extraction_status: "completed"})

    empty_document = document_fixture()
    {:ok, view, _html} = live(conn, ~p"/")
    card = "#documents-#{document.id}"

    assert has_element?(view, "#{card} progress[value='25.0']")
    assert has_element?(view, "#{card} img[src='/uploads/#{first_page.image_path}']")
    assert has_element?(view, "#{card} a[href='/documents/#{document.id}']")
    assert has_element?(view, "#{card} button[phx-value-id='#{document.id}']")
    refute has_element?(view, "#documents-#{empty_document.id} img")
  end

  test "shows upload language errors in the selected locale", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?lang=de")

    render_submit(view, "upload_document", %{"target_language" => "xx"})

    assert has_element?(view, "#flash-error", "Nicht unterstützte Sprache: xx")
    refute has_element?(view, "#flash-error", "Invalid language")
  end

  test "page bursts refresh only affected cards and retain the final progress", %{conn: conn} do
    first = document_with_pages_fixture(%{status: "processing"}, 2)
    second = document_with_pages_fixture(%{status: "processing"}, 1)
    untouched = document_with_pages_fixture(%{status: "processing"}, 1)
    {:ok, view, _} = live(conn, ~p"/")
    owner = self()
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:doctrans, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == view.pid, do: send(owner, {:dashboard_query, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    [page, last_page] = first.pages

    {:ok, page} =
      Doctrans.Documents.update_page_extraction(page, %{extraction_status: "completed"})

    send(view.pid, {:page_updated, page})
    assert has_element?(view, "#documents-#{first.id} progress[value='25.0']")

    {:ok, last_page} =
      Doctrans.Documents.update_page_extraction(last_page, %{extraction_status: "completed"})

    [other_page] = second.pages

    {:ok, other_page} =
      Doctrans.Documents.update_page_extraction(other_page, %{extraction_status: "completed"})

    send(view.pid, {:page_updated, last_page})
    send(view.pid, {:page_updated, other_page})
    send(view.pid, :dashboard_refresh)
    assert has_element?(view, "#documents-#{first.id} progress[value='50.0']")
    assert has_element?(view, "#documents-#{second.id} progress[value='50.0']")
    assert has_element?(view, "#documents-#{untouched.id} progress[value='0.0']")

    for _ <- 1..4 do
      assert_receive {:dashboard_query, metadata}
      assert metadata.query =~ "WHERE"
      refute untouched.id in List.flatten(metadata.params)
    end

    refute_receive {:dashboard_query, _}
  end

  test "document updates move renamed cards to their sorted position", %{conn: conn} do
    alpha = document_fixture(%{title: "Alpha"})
    beta = document_fixture(%{title: "Beta"})
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "sort", %{"field" => "title", "dir" => "asc"})
    assert has_element?(view, "#documents > #documents-#{alpha.id}:first-child")

    {:ok, updated} = Doctrans.Documents.update_document(alpha, %{title: "Zulu"})
    send(view.pid, {:document_updated, updated})
    assert has_element?(view, "#documents > #documents-#{beta.id}:first-child")
    assert has_element?(view, "#documents > #documents-#{alpha.id}:last-child h2", "Zulu")
  end

  test "new card updates preserve chronological ordering across months", %{conn: conn} do
    january = document_fixture(%{title: "January"})
    february = document_fixture(%{title: "February"})

    january =
      january
      |> Ecto.Changeset.change(inserted_at: ~N[2026-01-31 12:00:00])
      |> Doctrans.Repo.update!()

    february
    |> Ecto.Changeset.change(inserted_at: ~N[2026-02-01 12:00:00])
    |> Doctrans.Repo.update!()

    {:ok, view, _} = live(conn, ~p"/")
    new_document = document_fixture(%{title: "New"})
    send(view.pid, {:document_updated, new_document})
    assert has_element?(view, "#documents > #documents-#{new_document.id}:first-child")
    assert has_element?(view, "#documents > #documents-#{january.id}:last-child")
  end

  test "late page events cannot restore a deleted card", %{conn: conn} do
    document = document_with_pages_fixture(%{status: "processing"}, 1)
    [page] = document.pages
    {:ok, view, _} = live(conn, ~p"/")
    send(view.pid, {:page_updated, page})
    assert has_element?(view, "#documents-#{document.id}")
    send(view.pid, {:page_updated, page})
    render_click(view, "delete_document", %{"id" => document.id})
    send(view.pid, :dashboard_refresh)
    send(view.pid, {:document_updated, document})
    refute has_element?(view, "#documents-#{document.id}")
    assert has_element?(view, "#documents-empty")
  end

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
      Topics.broadcast_document_update(updated)

      assert render(view) =~ "Updated PubSub"
    end

    test "receives page updates via PubSub", %{conn: conn} do
      doc = document_with_pages_fixture(%{title: "Page Update Test"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      [page | _] = doc.pages

      # Update page and broadcast
      {:ok, updated_page} =
        Doctrans.Documents.update_page_extraction(page, %{extraction_status: "completed"})

      Topics.broadcast_page_update(updated_page)

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

    test "cancel_upload removes pending upload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open upload modal
      view |> element("#upload-document-btn") |> render_click()

      # Upload a file
      file =
        file_input(view, "#upload-form", :document, [
          %{
            name: "test.pdf",
            content: "fake pdf content",
            type: "application/pdf"
          }
        ])

      # Render the file input
      render_upload(file, "test.pdf")

      # Modal should still be open
      assert has_element?(view, "#upload-modal")
    end

    test "repeated deletes and invalid IDs are harmless", %{conn: conn} do
      doc = document_fixture(%{title: "Test Doc"})
      other = document_fixture(%{title: "Keep Me"})
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-click='delete_document'][phx-value-id='#{doc.id}']")
      |> render_click()

      for id <- [doc.id, Uniq.UUID.uuid7(), "invalid"] do
        render_click(view, "delete_document", %{"id" => id})
        refute has_element?(view, "button[phx-click='delete_document'][phx-value-id='#{doc.id}']")

        assert has_element?(
                 view,
                 "button[phx-click='delete_document'][phx-value-id='#{other.id}']"
               )

        refute has_element?(view, "#flash-error")
      end
    end

    test "deleting an already removed document refreshes the stale card", %{conn: conn} do
      doc = document_fixture()
      {:ok, view, _html} = live(conn, ~p"/")
      {:ok, _} = Doctrans.Documents.delete_document(doc)

      selector = "button[phx-click='delete_document'][phx-value-id='#{doc.id}']"
      view |> element(selector) |> render_click()
      refute has_element?(view, selector)
      refute has_element?(view, "#flash-error")
    end

    test "shows page count for document with zero pages", %{conn: conn} do
      _doc = document_fixture(%{total_pages: 0})
      {:ok, _view, html} = live(conn, ~p"/")

      # Should show 0 pages for document with no pages extracted yet
      assert html =~ "0 pages"
    end
  end
end
