defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Documents.{ProcessingStatus, Topics}

  alias DoctransWeb.DocumentLive.{
    ChatComponents,
    ChatSession,
    ReprocessModal,
    StatusPanel,
    Viewer
  }

  alias DoctransWeb.ErrorMessages

  import DoctransWeb.DocumentLive.Components,
    only: [language_direction: 1, processing_progress: 1]

  import DoctransWeb.DocumentLive.ViewerComponents

  import DoctransWeb.DocumentLive.ReprocessModal,
    only: [reprocess_modal: 1, reprocess_document_hint: 1]

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

  # Every event `Viewer` owns, forwarded the same way.
  @viewer_events ~w(
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
      |> Viewer.init(document)
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
      |> assign_origin(params)
      |> Viewer.apply_params(params)

    {:noreply, socket}
  end

  # Where the viewer was opened from, for the back link. `handle_params/3` runs
  # on every mount, so these need no placeholder before it.
  defp assign_origin(socket, params) do
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

  def handle_event(event, params, socket) when event in @viewer_events do
    Viewer.handle_event(event, params, socket)
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

  # PubSub handlers. Each broadcast goes to `Viewer`, which applies it and says
  # what changed; `ChatSession` reacts to that answer. Nothing is decided here.

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

  # The broadcast carries the committed row, so nothing is re-read here.
  def handle_info({:document_updated, document}, socket) do
    {change, socket} = Viewer.document_updated(socket, document)
    {:noreply, ChatSession.document_changed(socket, change)}
  end

  # Already showing not-found. Nothing to clear, and this socket may never have
  # mounted a document at all -- `mount/3` subscribes before it reads -- so it has
  # no chat assigns to reach for.
  @impl true
  def handle_info({:document_deleted, _id}, %{assigns: %{document: nil}} = socket) do
    {:noreply, socket}
  end

  # A deletion from elsewhere reaches this viewer on its own document topic.
  def handle_info({:document_deleted, _id}, socket) do
    {change, socket} = Viewer.document_deleted(socket)
    {:noreply, ChatSession.document_changed(socket, change)}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    {change, socket} = Viewer.page_updated(socket, page)
    {:noreply, ChatSession.page_changed(socket, change, page)}
  end

  def handle_info(:refresh_status, socket) do
    {:noreply, Viewer.refresh_pending(socket)}
  end

  # Streaming events from the chat turn in flight, and the timer that renders
  # the deltas it has buffered
  def handle_info(message, socket) when elem(message, 0) in [:chat_event, :chat_flush] do
    ChatSession.handle_info(message, socket)
  end
end
