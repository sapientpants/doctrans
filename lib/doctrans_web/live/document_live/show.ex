defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Run

  alias DoctransWeb.DocumentLive.{
    ChatComponents,
    ChatSession,
    PageViewer,
    ReprocessModal,
    StatusPanel
  }

  alias DoctransWeb.ErrorMessages

  import DoctransWeb.DocumentLive.Components,
    only: [language_direction: 1, processing_progress: 1]

  import DoctransWeb.DocumentLive.ViewerComponents

  import DoctransWeb.DocumentLive.PageViewer,
    only: [zoom_controls: 1, navigation: 1, view_tabs: 1, content_panel_label: 1]

  import DoctransWeb.DocumentLive.ReprocessModal,
    only: [reprocess_modal: 1, can_reprocess?: 1, can_reprocess_document?: 1]

  import DoctransWeb.DocumentLive.StatusPanel, only: [status_panel: 1]

  # Every event `ReprocessModal` owns. The modal is a function component, so the
  # events it declares arrive here and are forwarded verbatim.
  @reprocess_events ~w(
    show_reprocess_modal
    show_document_reprocess_modal
    hide_reprocess_modal
    update_reprocess_models
    retry_reprocess_models
    reprocess_page
    reprocess_document
  )

  # Every event `StatusPanel` owns, forwarded the same way. Each one is
  # re-authorized there against a freshly read status, so forwarding verbatim
  # costs this module no judgement about what is safe to run.
  @status_panel_events ~w(
    retry_indexing
    retry_failed_pages
    cancel_processing
  )

  # Every event `PageViewer` owns, forwarded the same way.
  @page_viewer_events ~w(
    prev_page
    next_page
    goto_page
    toggle_original
    zoom_in
    zoom_out
    select_view_tab
  )

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Subscribe before reading, and record the id in one place for both outcomes.
    #
    # Before, because a deletion committing between the read and the subscribe
    # would broadcast to nobody and leave this viewer rendering a document that
    # no longer exists, with nothing left to tell it otherwise. Subscribing first
    # makes the worst case a redundant `{:document_deleted, _}` for a row already
    # gone, which the handler below ignores.
    #
    # In one place, because `terminate/2` has to unsubscribe from the topic this
    # process actually took out -- and it cannot read the id back off `:document`,
    # which a deletion elsewhere clears out from under it. Assigning it here,
    # ahead of the branch, is what stops a mount path from forgetting to.
    #
    # Canonicalised first. `Ecto.UUID.cast/1` accepts an uppercase UUID and
    # downcases it, so `/documents/ABC...` loads the document fine while the raw
    # param would name a topic -- `document:ABC...` -- that no broadcast, which
    # always uses the stored id, ever reaches. Anything that is not a UUID at all
    # subscribes to nothing rather than turning a URL into a topic name.
    document_id = canonical_id(id)

    subscribed_document_id =
      if document_id && connected?(socket) do
        _ = Topics.subscribe_document(document_id)
        document_id
      end

    socket = assign(socket, :subscribed_document_id, subscribed_document_id)

    case document_id && Documents.get_document(document_id) do
      nil -> {:ok, assign(socket, :document, nil)}
      document -> mount_document(socket, document)
    end
  end

  defp canonical_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, canonical} -> canonical
      :error -> nil
    end
  end

  defp mount_document(socket, document) do
    socket =
      socket
      |> assign(:document, document)
      |> assign(:source_available, Run.source_available?(document))
      |> assign(:progress_refresh_pending, false)
      |> refresh_progress()
      |> PageViewer.init()
      |> assign(:from, nil)
      |> assign(:search_query, nil)
      |> assign(:search_page, nil)
      |> ReprocessModal.init()
      |> ChatSession.init(document)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{document: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> maybe_assign_from(params)
      |> PageViewer.apply_params(params)

    {:noreply, socket}
  end

  defp maybe_assign_from(socket, params) do
    from = Map.get(params, "from")
    search_query = Map.get(params, "q")
    search_page = Map.get(params, "search_page")

    socket
    |> assign(:from, from)
    |> assign(:search_query, search_query)
    |> assign(:search_page, search_page)
  end

  defp back_url("search", query, page) when is_binary(query) and query != "" do
    case page do
      nil -> ~p"/search?q=#{query}"
      "1" -> ~p"/search?q=#{query}"
      p -> ~p"/search?q=#{query}&page=#{p}"
    end
  end

  defp back_url(_from, _query, _page), do: ~p"/"

  @impl true
  def handle_event(_event, _params, %{assigns: %{document: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @page_viewer_events do
    PageViewer.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @reprocess_events do
    ReprocessModal.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @status_panel_events do
    StatusPanel.handle_event(event, params, socket)
  end

  # Chat event handlers

  @impl true
  def handle_event("toggle_chat", _params, socket) do
    {:noreply, ChatSession.toggle_open(socket)}
  end

  @impl true
  def handle_event("send_chat_message", %{"message" => message}, socket) do
    {:noreply, ChatSession.ask(socket, message)}
  end

  @impl true
  def handle_async(:fetch_models, result, socket) do
    ReprocessModal.handle_async(:fetch_models, result, socket)
  end

  def handle_async(:chat_turn, result, socket) do
    ChatSession.handle_async(:chat_turn, result, socket)
  end

  # PubSub Handlers

  @impl true
  def terminate(_reason, socket) do
    # No `connected?/1` check: `terminate/2` only runs for a connected LiveView,
    # and a disconnected mount leaves this assign nil, so the id alone decides.
    if socket.assigns.subscribed_document_id do
      Topics.unsubscribe_document(socket.assigns.subscribed_document_id)
    end

    :ok
  end

  # A document topic outlives its document: a job cancelled alongside a deletion
  # is not stopped synchronously, so it can still broadcast an update after
  # `{:document_deleted, _}` has emptied the assign. Nothing left to refresh.
  @impl true
  def handle_info({:document_updated, _document}, %{assigns: %{document: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:document_updated, _document}, socket) do
    document = Documents.get_document(socket.assigns.document.id)

    if document do
      changed? = document.processing_run_id != socket.assigns.document.processing_run_id
      socket = if changed?, do: ChatSession.interrupt(socket), else: socket

      {:noreply,
       socket
       |> assign(:document, document)
       |> assign(:source_available, Run.source_available?(document))
       |> PageViewer.goto_page(socket.assigns.current_page_number)
       |> refresh_progress()}
    else
      {:noreply, document_vanished(socket)}
    end
  end

  # Already showing not-found. Nothing to clear, and this socket may never have
  # mounted a document at all -- `mount/3` subscribes before it reads -- so it has
  # no chat assigns for `document_vanished/1` to reach for.
  @impl true
  def handle_info({:document_deleted, _id}, %{assigns: %{document: nil}} = socket) do
    {:noreply, socket}
  end

  # A deletion from elsewhere reaches this viewer on its own document topic. The
  # document is gone, so the assign says so and the template's not-found branch
  # renders -- the same landing as a `{:document_updated, _}` that re-reads a row
  # already deleted.
  def handle_info({:document_deleted, _id}, socket) do
    {:noreply, document_vanished(socket)}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    if socket.assigns.document && page.document_id == socket.assigns.document.id do
      socket =
        if socket.assigns.current_page_number == page.page_number,
          do:
            assign(
              socket,
              :current_page,
              Documents.get_page_by_number(page.document_id, page.page_number)
            ),
          else: socket

      socket =
        if socket.assigns.progress_refresh_pending do
          socket
        else
          Process.send_after(self(), :refresh_progress, 100)
          assign(socket, :progress_refresh_pending, true)
        end

      {:noreply,
       socket |> ChatSession.prune_context(page) |> ChatSession.refresh_embeddings_status()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_progress, socket) do
    {:noreply, socket |> assign(:progress_refresh_pending, false) |> refresh_progress()}
  end

  # Streaming events from the chat turn in flight
  def handle_info({:chat_event, _token, _event} = message, socket) do
    ChatSession.handle_info(message, socket)
  end

  defp refresh_progress(%{assigns: %{document: nil}} = socket), do: socket

  defp refresh_progress(socket) do
    case Documents.list_documents_with_progress(document_ids: [socket.assigns.document.id]) do
      [summary] ->
        socket
        |> assign(:processing_progress, summary.progress)
        |> assign(:failed_pages, summary.failed_pages)

      [] ->
        socket |> assign(:processing_progress, 0.0) |> assign(:failed_pages, [])
    end
    |> StatusPanel.refresh()
  end

  # The document this viewer is on has gone: deleted in another tab, or already
  # gone by the time a `{:document_updated, _}` made us re-read it. A turn in
  # flight is stopped with it; `ChatSession.interrupt/1` says why it cannot wait.
  defp document_vanished(socket) do
    socket |> ChatSession.interrupt() |> assign(:document, nil)
  end

  # Names the reprocess-document button and fills its tooltip. The two must say
  # the same thing: `aria-label` overrides `title` for the accessible name, so a
  # tooltip-only explanation of why the button is disabled never reaches a
  # screen reader.
  defp reprocess_document_hint(true), do: gettext("Reprocess document")

  defp reprocess_document_hint(false) do
    gettext("Original upload unavailable. Re-upload this document to process it again.")
  end
end
