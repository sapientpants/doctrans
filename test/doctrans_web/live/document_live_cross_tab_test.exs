defmodule DoctransWeb.DocumentLive.CrossTabTest do
  @moduledoc """
  The dashboard's half of the cross-tab broadcasts: an upload, a deletion, or a
  status change made anywhere reaches every dashboard that is already open, and
  the single collection subscription that carries them does not grow with the
  document list.

  Every case here drives the real context function and lets the broadcast travel
  on its own. Sending `{:document_created, _}` straight to `view.pid` would prove
  only that a `handle_info/2` clause exists -- it would keep passing if nothing
  ever broadcast, which is precisely the gap these cases close.

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
  alias Doctrans.TestEnv
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
      Topics.broadcast_document_updated(updated)

      assert has_element?(observer, "#{card} .badge", "Completed")

      [page, _second] = document.pages

      {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "completed"})
      Topics.broadcast_page_updated(page)

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

      # A bare socket on purpose. The dashboard used to unsubscribe from a list of
      # per-document topics it kept in its assigns, and the whole point of the
      # single collection subscription is that `terminate/2` no longer needs to
      # read anything off the socket to release it. An empty `assigns` is a real
      # socket rather than a stand-in, so reaching for an assign here raises
      # instead of quietly passing.
      assert :ok = Index.terminate(:shutdown, %Phoenix.LiveView.Socket{})

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

      # The viewer's own socket, taken from the running process rather than
      # authored here: it is already in the state a deletion leaves behind, with
      # `:document` cleared. Writing those assigns by hand instead would assert
      # nothing about `mount/3` -- the test would keep passing if the viewer
      # stopped recording the id it subscribed with, which is the one thing
      # `terminate/2` cannot get from anywhere else.
      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.document == nil

      assert :ok = Show.terminate(:shutdown, socket)

      refute topic in Registry.keys(Doctrans.PubSub, self())
    end

    test "a viewer reached through an uppercase id still hears its deletion", %{conn: conn} do
      document = document_fixture(%{title: "Shouty"})
      upper = String.upcase(document.id)

      # `Ecto.UUID.cast/1` downcases, so this URL loads the document. The topic
      # has to be the stored id all the same -- subscribing with the raw param
      # would name `document:<UPPER>`, which nothing ever broadcasts to, and the
      # viewer would sit there rendering a document that no longer exists.
      {:ok, view, _html} = live(conn, ~p"/documents/#{upper}")
      refute has_element?(view, "#document-not-found")

      {:ok, _} = Documents.delete_document(document)

      assert has_element?(view, "#document-not-found")
    end

    test "a viewer that never found its document still releases the topic", %{conn: conn} do
      missing = Ecto.UUID.generate()
      topic = "document:#{missing}"

      {:ok, view, _html} = live(conn, ~p"/documents/#{missing}")
      assert has_element?(view, "#document-not-found")

      # `mount/3` subscribes before it reads, so the not-found branch holds a
      # subscription too and has the same release to make. This is the path that
      # used to be able to drop the assign without a single test noticing --
      # `terminate/2` reads it unconditionally, and a crash on the way out is
      # only logged, never failed on.
      assert Registry.keys(Doctrans.PubSub, view.pid) == [topic]

      :ok = Topics.subscribe_document(missing)
      socket = :sys.get_state(view.pid).socket
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

  describe "the serial constraint this file documents" do
    test "the runtime guard rejects dashboard mounts through wrapped connections", %{conn: conn} do
      Doctrans.TestEnv.record_async(async: true)

      assert_raise ArgumentError, ~r/Dashboard LiveView tests must use async: false/, fn ->
        live(put_req_header(conn, "accept-language", "de"), ~p"/?lang=de")
      end
    end

    test "the runtime guard rejects connected mounts and live navigation too", %{conn: conn} do
      rendered = get(conn, ~p"/")
      Doctrans.TestEnv.record_async(async: true)

      assert_raise ArgumentError, ~r/Dashboard LiveView tests must use async: false/, fn ->
        live(rendered)
      end

      {:ok, search, _} = live(conn, ~p"/search")

      assert_raise ArgumentError, ~r/Dashboard LiveView tests must use async: false/, fn ->
        live_redirect(search, to: ~p"/")
      end

      assert_raise ArgumentError, ~r/Dashboard LiveView tests must use async: false/, fn ->
        follow_redirect({:error, {:live_redirect, %{to: ~p"/"}}}, conn)
      end
    end
  end

  describe "a chat turn whose document is deleted elsewhere" do
    test "is killed rather than left running against rows that are gone", %{conn: conn} do
      document = completed_document_with_embedding_fixture()
      question = "What does this document say?"
      barrier = install_barrier(question)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("header button[phx-click='toggle_chat']") |> render_click()
      view |> form("#chat-form", %{"message" => question}) |> render_submit()

      # Parked inside the agent pipeline, which is where a real turn spends its
      # time. The task is `async_nolink`, so nothing that happens to the LiveView
      # or to the document reaches it on its own.
      assert_receive {:embedding_started, ^barrier, task_pid}, 2_000
      monitor = Process.monitor(task_pid)

      {:ok, _} = Documents.delete_document(document)

      # The turn is stopped when the document goes, not when its answer lands.
      # Left alone it would run the rest of the pipeline -- several LLM calls, a
      # 300s receive timeout each -- to produce an answer whose chat session
      # cascaded away with the row, and it would outlive the viewer as well.
      assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}, 2_000

      assert has_element?(view, "#document-not-found")
      assert Process.alive?(view.pid)
    end

    test "a landing that was already in flight is dropped by the live viewer", %{conn: conn} do
      document = document_fixture(%{title: "Doomed"})
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      {:ok, _} = Documents.delete_document(document)
      assert has_element?(view, "#document-not-found")

      # Both shapes a killed turn can still deliver: a result sent before the kill
      # landed, and a `:DOWN` for a monitor already flushed. `interrupt_chat/1`
      # cleared `chat_task_ref`, so each is identified by its ref -- not by having
      # turned up late -- and falls to the stale-ref clauses that drop it.
      send(view.pid, {make_ref(), {:ok, "Stale answer", []}})
      send(view.pid, {:DOWN, make_ref(), :process, self(), :boom})

      # Rendering round-trips through the viewer, so a message that killed it
      # fails here rather than going unnoticed.
      assert has_element?(view, "#document-not-found")
      assert Process.alive?(view.pid)
    end
  end

  # Parks the embedding stub on `text` until this test releases it, so a chat
  # turn can be observed mid-flight.
  defp install_barrier(text) do
    barrier = make_ref()
    TestEnv.put_env(:embedding_stub_barrier, {text, self(), barrier})
    barrier
  end

  defp insert_without_broadcast(title) do
    Repo.insert!(%Document{
      title: title,
      original_filename: "#{title}.pdf",
      source_language: "de",
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

    # `documents_count` drives the empty state and nothing else, so on its own it
    # only ever shows up as zero-or-not: a count that drifts while cards are still
    # on screen stays hidden until the last delete fails to bring the empty state
    # back. Pinned against the cards here, every case in this file checks it.
    assert has_element?(view, "#documents[data-documents-count='#{length(ids)}']")
    assert has_element?(view, "#documents-empty") == (ids == [])

    # Structural, not cosmetic. `Index`'s template explains why an id-bearing
    # child cannot live inside the stream container; this is the assertion that
    # holds it to that, by requiring everything in `#documents` to be a stream
    # child.
    refute has_element?(view, "#documents > :not([data-phx-stream])")
  end
end
