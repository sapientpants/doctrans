defmodule DoctransWeb.DocumentLive.IndexTest do
  # Sync on purpose, and it must stay that way. These tests mount `Index`, which
  # subscribes to the process-global `"documents"` PubSub topic; the Ecto SQL
  # sandbox isolates the database but not PubSub, so under `async: true` a
  # `document_fixture/1` or a page broadcast from any concurrently running file
  # lands in this file's dashboards and makes them re-query and re-render for
  # documents this file never created. Neither "only the affected cards were
  # re-queried" below nor the progress assertions can hold against that traffic.
  # ExUnit starts sync modules only once every async module has finished and
  # runs them one at a time, so serializing is what keeps it away.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
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

  test "an errored card names the pages to reprocess", %{conn: conn} do
    document = document_with_pages_fixture(%{status: "error"}, 2)
    [failed, done] = document.pages

    {:ok, _} = Documents.update_page_extraction(failed, %{extraction_status: "error"})
    {:ok, done} = Documents.update_page_extraction(done, %{extraction_status: "completed"})
    {:ok, _} = Documents.update_page_translation(done, %{translation_status: "completed"})

    whole = document_fixture(%{status: "error", total_pages: 2})

    {:ok, view, _html} = live(conn, ~p"/")
    failure = "#document-progress-#{document.id}-failure"

    assert has_element?(view, "#{failure}[data-failed-pages='1']")
    assert has_element?(view, failure, "page(s) 1")
    assert has_element?(view, "#document-progress-#{whole.id}-failure[data-failed-pages='']")
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

      # `cast_params`, not `params`: `params` carries UUIDs already dumped to
      # 16-byte binaries, so a string id can never appear in it and the
      # refutation would hold no matter which rows the dashboard asked for.
      refute untouched.id in List.flatten(List.wrap(metadata.cast_params))
    end

    # This file is sync, so the only queries this dashboard can be making are
    # the ones the sends above provoked; a further one means a card was
    # refreshed that had no reason to be.
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

  for dir <- ~w(asc desc) do
    test "incremental title updates match database ordering (#{dir})", %{conn: conn} do
      [document | _] =
        for title <- ["apple", "Banana", "cherry", "Zebra", "Äpfel"] do
          document_fixture(%{title: title})
        end

      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "sort", %{"field" => "title", "dir" => unquote(dir)})

      {:ok, updated} = Documents.update_document(document, %{title: "apricot"})
      send(view.pid, {:document_updated, updated})
      assert_title_order(view, unquote(dir))

      new_document = document_fixture(%{title: "ábaco"})
      send(view.pid, {:document_updated, new_document})
      assert_title_order(view, unquote(dir))
    end

    test "queued document renames preserve ordering (#{dir})", %{conn: conn} do
      [a, _b, _c, d, _e] =
        for title <- ["A", "B", "C", "D", "E"], do: document_fixture(%{title: title})

      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "sort", %{"field" => "title", "dir" => unquote(dir)})

      {:ok, d} = Documents.update_document(d, %{title: "BB"})
      {:ok, a} = Documents.update_document(a, %{title: "ZZ"})
      send(view.pid, {:document_updated, d})
      assert has_element?(view, "#documents-#{d.id} h2", "BB")
      send(view.pid, {:document_updated, a})
      assert_title_order(view, unquote(dir))
    end

    test "coalesced renames preserve final batch ordering (#{dir})", %{conn: conn} do
      [a, _b, c, d, e] =
        for title <- ["A", "B", "C", "D", "E"] do
          document_with_pages_fixture(%{title: title}, 1)
        end

      {:ok, view, _} = live(conn, ~p"/")
      render_click(view, "sort", %{"field" => "title", "dir" => unquote(dir)})
      send(view.pid, {:page_updated, hd(e.pages)})
      assert has_element?(view, "#documents-#{e.id}")

      {:ok, _} = Documents.update_document(d, %{title: "BB"})
      {:ok, _} = Documents.update_document(a, %{title: "ZZ"})
      send(view.pid, {:page_updated, hd(d.pages)})
      send(view.pid, {:page_updated, hd(a.pages)})
      send(view.pid, :dashboard_refresh)
      assert_title_order(view, unquote(dir))

      # A second batch also includes a progress-only card between moved cards.
      send(view.pid, {:page_updated, hd(e.pages)})
      assert has_element?(view, "#documents-#{e.id}")
      {:ok, _} = Documents.update_document(d, %{title: "Z"})
      {:ok, _} = Documents.update_document(a, %{title: "AA"})
      send(view.pid, {:page_updated, hd(d.pages)})
      send(view.pid, {:page_updated, hd(c.pages)})
      send(view.pid, {:page_updated, hd(a.pages)})
      send(view.pid, :dashboard_refresh)
      assert_title_order(view, unquote(dir))
    end
  end

  defp assert_title_order(view, dir) do
    sort_dir = if dir == "asc", do: :asc, else: :desc
    summaries = Documents.list_documents_with_progress(sort_by: :title, sort_dir: sort_dir)

    for {summary, index} <- Enum.with_index(summaries, 1) do
      assert has_element?(
               view,
               "#documents > #documents-#{summary.id}:nth-child(#{index}) h2",
               summary.document.title
             )
    end
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
      assert has_element?(view, "#documents progress")
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
      older = document_fixture(%{title: "Zebra"})
      newer = document_fixture(%{title: "Alpha"})

      for {document, timestamp} <- [
            {older, ~N[2020-01-01 12:00:00]},
            {newer, ~N[2021-01-01 12:00:00]}
          ] do
        document |> Ecto.Changeset.change(inserted_at: timestamp) |> Doctrans.Repo.update!()
      end

      {:ok, view, _html} = live(conn, ~p"/")

      for {field, direction, expected} <- [
            {"title", "desc", [older.id, newer.id]},
            {"title", "asc", [newer.id, older.id]},
            {"inserted_at", "asc", [older.id, newer.id]},
            {"inserted_at", "desc", [newer.id, older.id]}
          ] do
        view
        |> element(
          "button[phx-click='sort'][phx-value-field='#{field}'][phx-value-dir='#{direction}']"
        )
        |> render_click()

        ids =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("#documents > div")
          |> LazyHTML.attribute("id")

        assert ids == Enum.map(expected, &"documents-#{&1}")
      end
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

    test "shows progress bar for extracting documents", %{conn: conn} do
      _doc = document_with_pages_fixture(%{status: "extracting"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#documents progress")
    end

    test "receives document updates via PubSub", %{conn: conn} do
      doc = document_fixture(%{title: "Initial"})
      {:ok, view, _html} = live(conn, ~p"/")

      # Verify initial state
      assert render(view) =~ "Initial"

      # Update and broadcast
      {:ok, updated} = Doctrans.Documents.update_document(doc, %{title: "Updated PubSub"})
      Topics.broadcast_document_updated(updated)

      assert render(view) =~ "Updated PubSub"
    end

    # Page progress reaches the dashboard on the collection topic, which is the
    # only subscription it holds since the per-document ones were dropped.
    test "receives page updates via PubSub", %{conn: conn} do
      doc = document_with_pages_fixture(%{title: "Page Update Test", status: "processing"}, 2)
      other = document_with_pages_fixture(%{title: "Untouched", status: "processing"}, 2)
      {:ok, view, _html} = live(conn, ~p"/")

      [page | _] = doc.pages

      # Update page and broadcast
      {:ok, updated_page} =
        Doctrans.Documents.update_page_extraction(page, %{extraction_status: "completed"})

      Topics.broadcast_page_updated(updated_page)

      assert has_element?(view, "#documents-#{doc.id} progress[value='25.0']")
      assert has_element?(view, "#documents-#{other.id} progress[value='0.0']")
    end

    test "validate_upload changes target language", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#upload-document-btn") |> render_click()

      # The upload form validates changes
      view
      |> element("#upload-form")
      |> render_change(%{"target_language" => "fr"})

      assert has_element?(view, "#target-lang-select option[value='fr'][selected]")
      refute has_element?(view, "#target-lang-select option[value='en'][selected]")
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
      view |> element("#upload-document-btn") |> render_click()

      for name <- ["removed.pdf", "retained.pdf"] do
        upload =
          file_input(view, "#upload-form", :document, [
            %{name: name, content: "%PDF-1.7\nretained source bytes", type: "application/pdf"}
          ])

        render_upload(upload, name)
      end

      view
      |> element("button[phx-click=cancel_upload][aria-label*='removed.pdf']")
      |> render_click()

      refute has_element?(view, "button[phx-click=cancel_upload][aria-label*='removed.pdf']")
      assert has_element?(view, "button[phx-click=cancel_upload][aria-label*='retained.pdf']")
      assert has_element?(view, "#upload-modal")

      put_oban_manual_mode(view)

      Oban.Testing.with_testing_mode(:manual, fn ->
        view |> form("#upload-form", %{target_language: "en"}) |> render_submit()
      end)

      assert [document] = Documents.list_documents()
      directory = Documents.document_upload_dir(document.id)
      on_exit(fn -> File.rm_rf!(directory) end)
      assert document.original_filename == "retained.pdf"
      assert File.read!(Path.join(directory, "original.pdf")) == "%PDF-1.7\nretained source bytes"
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

    # The card used to go stale until something else refreshed it; the deletion
    # is now broadcast, so an open dashboard drops the card on its own. The
    # defensive path this test used to cover -- clicking delete for an id the
    # dashboard no longer tracks -- is exercised by "repeated deletes and invalid
    # IDs are harmless" above, which drives the event directly.
    test "a deletion elsewhere removes the card from an open dashboard", %{conn: conn} do
      doc = document_fixture(%{title: "Removed Elsewhere"})
      kept = document_fixture(%{title: "Kept"})
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#documents-#{doc.id}")

      {:ok, _} = Doctrans.Documents.delete_document(doc)

      refute has_element?(view, "#documents-#{doc.id}")
      assert has_element?(view, "#documents-#{kept.id}")
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
