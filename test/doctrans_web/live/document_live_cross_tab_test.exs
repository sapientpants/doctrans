defmodule DoctransWeb.DocumentLive.CrossTabTest do
  @moduledoc """
  The dashboard's half of U11: an upload, a deletion, or a status change made
  anywhere reaches every dashboard that is already open, and the single
  collection subscription that carries them does not grow with the document list.

  Every case here drives the real context function and lets the broadcast travel
  on its own. Sending `{:document_created, _}` straight to `view.pid` would prove
  only that a `handle_info/2` clause exists -- it would keep passing if nothing
  ever broadcast, which is precisely the gap U11 closes.

  The viewer's matching bound belongs here too: the deletion that can strand a
  `document:<id>` subscription is a cross-tab one, so "subscriptions remain
  bounded" is only true if the viewer releases that topic as well.
  """
  # Sync on purpose, and it must stay that way. These tests mount `Index`, which
  # subscribes to the process-global `"documents"` PubSub topic; the Ecto SQL
  # sandbox isolates the database but not PubSub, so under `async: true` a
  # `document_fixture/1` or a page broadcast from any concurrently running file
  # lands in this file's dashboards. That foreign traffic sets the dashboard's
  # coalescing timer, which pushes this file's own update into the trailing
  # refresh and makes the progress assertions below race. ExUnit starts sync
  # modules only once every async module has finished and runs them one at a
  # time, so serializing is what actually stops the broadcast from arriving.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Document
  alias Doctrans.Documents.Topics
  alias Doctrans.Repo
  alias DoctransWeb.DocumentLive.Index
  alias DoctransWeb.DocumentLive.Show

  import Doctrans.Fixtures

  describe "cross-tab creation" do
    test "an upload reaches a dashboard that was already open", %{conn: conn} do
      existing = document_fixture(%{title: "Already Here"})
      {:ok, first, _html} = live(conn, ~p"/")
      {:ok, second, _html} = live(conn, ~p"/")

      # Both tabs mounted holding only `existing`, so a second card appearing
      # later can only have arrived over PubSub.
      for view <- [first, second], do: assert_cards(view, [existing.id])

      uploaded = document_fixture(%{title: "Uploaded Elsewhere"})

      for view <- [first, second] do
        assert has_element?(view, "#documents-#{uploaded.id} h2", "Uploaded Elsewhere")
        assert_cards(view, [uploaded.id, existing.id])
        refute has_element?(view, "#flash-error")
      end
    end

    test "an upload reaches a dashboard that mounted with nothing on it", %{conn: conn} do
      {:ok, first, _html} = live(conn, ~p"/")
      {:ok, second, _html} = live(conn, ~p"/")
      assert has_element?(first, "#documents-empty")
      assert has_element?(second, "#documents-empty")

      uploaded = document_fixture(%{title: "Uploaded Elsewhere"})

      for view <- [first, second] do
        assert has_element?(view, "#documents-#{uploaded.id} h2", "Uploaded Elsewhere")
        refute has_element?(view, "#documents-empty")
        assert_cards(view, [uploaded.id])
        refute has_element?(view, "#flash-error")
      end
    end

    test "the new card lands in its sorted position in every tab", %{conn: conn} do
      alpha = document_fixture(%{title: "Alpha"})
      charlie = document_fixture(%{title: "Charlie"})
      {:ok, first, _html} = live(conn, ~p"/")
      {:ok, second, _html} = live(conn, ~p"/")

      for view <- [first, second] do
        render_click(view, "sort", %{"field" => "title", "dir" => "asc"})
        assert_cards(view, [alpha.id, charlie.id])
      end

      bravo = document_fixture(%{title: "Bravo"})

      for view <- [first, second] do
        assert_cards(view, [alpha.id, bravo.id, charlie.id])
      end
    end
  end

  describe "cross-tab deletion" do
    test "deleting in one tab removes the card from the other", %{conn: conn} do
      doomed = document_fixture(%{title: "Doomed"})
      kept = document_fixture(%{title: "Kept"})
      {:ok, actor, _html} = live(conn, ~p"/")
      {:ok, observer, _html} = live(conn, ~p"/")
      assert has_element?(observer, "#documents-#{doomed.id}")

      actor
      |> element("button[phx-click='delete_document'][phx-value-id='#{doomed.id}']")
      |> render_click()

      refute has_element?(observer, "#documents-#{doomed.id}")
      assert has_element?(observer, "#documents-#{kept.id}")
      refute has_element?(observer, "#flash-error")
    end

    test "a deletion from outside any tab removes the card", %{conn: conn} do
      doomed = document_fixture(%{title: "Doomed"})
      kept = document_fixture(%{title: "Kept"})
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#documents-#{doomed.id}")

      # Stands in for a deletion that did not originate in a LiveView at all.
      {:ok, _} = Documents.delete_document(doomed)

      refute has_element?(view, "#documents-#{doomed.id}")
      assert has_element?(view, "#documents-#{kept.id}")
      refute has_element?(view, "#flash-error")
    end
  end

  describe "cross-tab status changes" do
    test "document and page updates still reach a second tab", %{conn: conn} do
      document = document_with_pages_fixture(%{title: "Working", status: "processing"}, 2)
      untouched = document_with_pages_fixture(%{title: "Untouched", status: "processing"}, 2)
      {:ok, _actor, _html} = live(conn, ~p"/")
      {:ok, observer, _html} = live(conn, ~p"/")
      card = "#documents-#{document.id}"

      assert has_element?(observer, "#{card} .badge", "Processing")

      {:ok, updated} = Documents.update_document(document, %{status: "completed"})
      Topics.broadcast_document_update(updated)

      assert has_element?(observer, "#{card} .badge", "Completed")

      [page, _second] = document.pages

      {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "completed"})
      Topics.broadcast_page_update(page)

      assert has_element?(observer, "#{card} progress[value='25.0']")
      assert has_element?(observer, "#documents-#{untouched.id} progress[value='0.0']")
    end
  end

  describe "bounded subscriptions" do
    test "one subscription regardless of how many documents are on screen", %{conn: conn} do
      for title <- ~w(Alpha Bravo Charlie Delta), do: document_fixture(%{title: title})
      {:ok, view, _html} = live(conn, ~p"/")

      # `Doctrans.PubSub` is the name of the duplicate `Registry` the PubSub
      # adapter registers subscribers in, so its keys for a pid are exactly that
      # process's subscribed topics -- repeats included, which is what makes this
      # a real bound and not a set membership check.
      assert Registry.keys(Doctrans.PubSub, view.pid) == ["documents"]

      echo = document_fixture(%{title: "Echo"})
      assert has_element?(view, "#documents-#{echo.id}")
      assert Registry.keys(Doctrans.PubSub, view.pid) == ["documents"]

      view
      |> element("button[phx-click='delete_document'][phx-value-id='#{echo.id}']")
      |> render_click()

      refute has_element?(view, "#documents-#{echo.id}")
      assert Registry.keys(Doctrans.PubSub, view.pid) == ["documents"]
    end

    test "a second subscription would be visible to this check" do
      :ok = Topics.subscribe_documents()
      :ok = Topics.subscribe_documents()

      # Guards the assertion above: `Registry.keys/2` on a duplicate registry
      # reports each registration, so a leak really would show up as growth.
      assert Registry.keys(Doctrans.PubSub, self()) == ["documents", "documents"]
    end

    test "terminate/2 releases the collection subscription" do
      :ok = Topics.subscribe_documents()
      assert "documents" in Registry.keys(Doctrans.PubSub, self())

      assert :ok = Index.terminate(:shutdown, :unused_socket)

      refute "documents" in Registry.keys(Doctrans.PubSub, self())
    end

    test "a viewer releases its document topic even after the document is deleted", %{conn: conn} do
      document = document_fixture(%{title: "Doomed"})
      topic = "document:#{document.id}"

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      # The viewer's entire budget: the one per-document topic `mount/3` takes out.
      assert Registry.keys(Doctrans.PubSub, view.pid) == [topic]

      # This process now stands in for that viewer -- it holds the same
      # registration, and `Registry.keys/2` cannot speak for a pid that has
      # already exited, which is the only way a real viewer reaches `terminate/2`.
      :ok = Topics.subscribe_document(document.id)
      {:ok, _} = Documents.delete_document(document)
      assert has_element?(view, "#document-not-found")

      # The assigns a viewer is left holding once the deletion broadcast has
      # cleared `:document`: navigating away from here must still unsubscribe,
      # so the id has to have been remembered somewhere the deletion cannot reach.
      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        assigns: %{__changed__: %{}, document: nil, subscribed_document_id: document.id}
      }

      assert :ok = Show.terminate(:shutdown, socket)

      refute topic in Registry.keys(Doctrans.PubSub, self())
    end
  end

  describe "stream consistency" do
    test "a create and a delete leave the card set, order and count agreeing", %{conn: conn} do
      alpha = document_fixture(%{title: "Alpha"})
      charlie = document_fixture(%{title: "Charlie"})
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "sort", %{"field" => "title", "dir" => "asc"})

      bravo = document_fixture(%{title: "Bravo"})
      assert_cards(view, [alpha.id, bravo.id, charlie.id])

      {:ok, charlie} = Documents.delete_document(charlie)
      assert_cards(view, [alpha.id, bravo.id])

      # A duplicate deletion -- the shape the deleting tab sees, where the event
      # handler has already removed the card and the broadcast arrives after it.
      :ok = Topics.broadcast_document_deleted(charlie)
      assert_cards(view, [alpha.id, bravo.id])
    end

    test "the deleting tab handles its own broadcast without losing a card", %{conn: conn} do
      alpha = document_fixture(%{title: "Alpha"})
      bravo = document_fixture(%{title: "Bravo"})
      charlie = document_fixture(%{title: "Charlie"})
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "sort", %{"field" => "title", "dir" => "asc"})

      view
      |> element("button[phx-click='delete_document'][phx-value-id='#{bravo.id}']")
      |> render_click()

      # The click removed the card; the tab's own `{:document_deleted, _}` is
      # queued behind it and is handled before this render.
      assert_cards(view, [alpha.id, charlie.id])

      view
      |> element("button[phx-click='delete_document'][phx-value-id='#{alpha.id}']")
      |> render_click()

      assert_cards(view, [charlie.id])

      {:ok, _} = Documents.delete_document(charlie)
      assert has_element?(view, "#documents-empty")
    end

    test "a sort's stream reset picks up a row that arrived with no broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_cards(view, [])

      # Inserted straight into the repo, so no `{:document_created, _}` is
      # broadcast and nothing folds this card in incrementally. The only thing
      # that can put it on screen is the `stream(..., reset: true)` that the sort
      # click runs through `DocumentStream.refresh/1`.
      document = insert_without_broadcast("Sorted In")

      render_click(view, "sort", %{"field" => "title", "dir" => "asc"})

      assert_cards(view, [document.id])
    end
  end

  describe "empty state" do
    test "deleting the last card elsewhere brings the empty state back", %{conn: conn} do
      only = document_fixture(%{title: "Only"})
      {:ok, view, _html} = live(conn, ~p"/")
      assert_cards(view, [only.id])
      refute has_element?(view, "#documents-empty")

      {:ok, _} = Documents.delete_document(only)

      assert_cards(view, [])
      assert has_element?(view, "#documents-empty")
    end
  end

  defp insert_without_broadcast(title) do
    Repo.insert!(%Document{
      title: title,
      original_filename: "#{title}.pdf",
      target_language: "en",
      status: "uploading"
    })
  end

  # Pins the whole visible card set: every id at its position and nothing beyond
  # it, so a card that lingers after a delete or doubles after a repeat shows up.
  defp assert_cards(view, ids) do
    for {id, index} <- Enum.with_index(ids, 1) do
      assert has_element?(view, "#documents > #documents-#{id}:nth-child(#{index})")
    end

    refute has_element?(view, "#documents > div:nth-child(#{length(ids) + 1})")

    # Structural, not cosmetic: the client refuses to discard an id-bearing child
    # of a stream container and a reset only removes `data-phx-stream` children,
    # so anything else parked in here -- the empty state above all -- would stay
    # on screen forever. Everything inside `#documents` is a stream child.
    refute has_element?(view, "#documents > :not([data-phx-stream])")
  end
end
