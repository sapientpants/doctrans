defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Run
  alias DoctransWeb.DocumentLive.{ChatSession, PageViewer, ReprocessModal}
  alias DoctransWeb.ErrorMessages

  import DoctransWeb.DocumentLive.Components,
    only: [status_color: 1, status_text: 1, language_name: 1, processing_progress: 1]

  import DoctransWeb.DocumentLive.ViewerComponents

  import DoctransWeb.DocumentLive.PageViewer,
    only: [zoom_controls: 1, navigation: 1, view_tabs: 1, content_panel_label: 1]

  import DoctransWeb.DocumentLive.ReprocessModal, only: [reprocess_modal: 1, can_reprocess?: 1]
  import DoctransWeb.DocumentLive.ChatComponents

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
    case Documents.get_document(id) do
      nil ->
        # `terminate/2` reads this assign, so the not-found path has to set it too.
        {:ok, socket |> assign(:document, nil) |> assign(:subscribed_document_id, nil)}

      document ->
        mount_document(socket, document)
    end
  end

  defp mount_document(socket, document) do
    # Remembered separately from `:document`, which a deletion elsewhere clears
    # out from under us: `terminate/2` has to unsubscribe from the topic this
    # process actually subscribed to, whatever became of the row behind it.
    subscribed_document_id =
      if connected?(socket) do
        _ = Topics.subscribe_document(document.id)
        document.id
      else
        nil
      end

    socket =
      socket
      |> assign(:document, document)
      |> assign(:subscribed_document_id, subscribed_document_id)
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

  # PubSub Handlers

  @impl true
  def terminate(_reason, socket) do
    if connected?(socket) && socket.assigns.subscribed_document_id do
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
      socket = if changed?, do: interrupt_chat(socket), else: socket

      number =
        min(
          socket.assigns.current_page_number,
          document.total_pages || socket.assigns.current_page_number
        )

      {:noreply,
       socket
       |> assign(:document, document)
       |> assign(:source_available, Run.source_available?(document))
       |> PageViewer.apply_params(%{"page" => to_string(max(1, number))})
       |> refresh_progress()}
    else
      {:noreply, assign(socket, :document, nil)}
    end
  end

  # A deletion from elsewhere reaches this viewer on its own document topic. The
  # document is gone, so the assign says so and the template's not-found branch
  # renders, exactly as when the clause above re-reads a document that has vanished.
  @impl true
  def handle_info({:document_deleted, _id}, socket) do
    {:noreply, assign(socket, :document, nil)}
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

  def handle_info({:chat_event, token, event}, socket) do
    if token == socket.assigns.chat_token,
      do: handle_info({:chat_event, event}, socket),
      else: {:noreply, socket}
  end

  # Chat streaming/progress events from the agent pipeline

  @impl true
  def handle_info({:chat_event, _event}, %{assigns: %{chat_loading: false}} = socket),
    do: {:noreply, socket}

  def handle_info({:chat_event, {:stage, stage}}, socket) do
    {:noreply, assign(socket, :chat_stage, stage)}
  end

  @impl true
  def handle_info({:chat_event, {:delta, text}}, socket) do
    {:noreply,
     assign(socket, :chat_streaming_content, socket.assigns.chat_streaming_content <> text)}
  end

  # Chat response handlers (async_nolink pattern)

  # A turn can outlive its document: `Worker.cancel_document/1` does not reach a
  # task this LiveView spawned, so a deletion elsewhere empties `:document` while
  # the answer is still generating. Both landings below write through
  # `Doctrans.Chat.Conversations`, which fences the answer against the document's
  # current run and saves it into a chat session that cascaded away with the row --
  # so with no document there is nothing left to save the turn against, and it is
  # dropped instead. The viewer is already showing the not-found branch, where the
  # chat panel does not render.
  @impl true
  def handle_info({ref, _result}, %{assigns: %{document: nil}} = socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, interrupt_chat(socket)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{document: nil}} = socket)
      when is_reference(ref) do
    {:noreply, interrupt_chat(socket)}
  end

  @impl true
  def handle_info({ref, {:ok, response, retrieved_context}}, socket)
      when socket.assigns.chat_task_ref == ref do
    # Flush the :DOWN message
    Process.demonitor(ref, [:flush])

    case ChatSession.put_response(socket, response, retrieved_context) do
      {:ok, socket} -> {:noreply, socket}
      {:error, :obsolete_run} -> {:noreply, interrupt_chat(socket)}
    end
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) when socket.assigns.chat_task_ref == ref do
    Process.demonitor(ref, [:flush])
    {:noreply, ChatSession.put_failure(socket, reason)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when socket.assigns.chat_task_ref == ref do
    # :normal = success (result already handled); only error on crashes
    if reason == :normal,
      do: {:noreply, socket},
      else: {:noreply, ChatSession.put_failure(socket, :unknown)}
  end

  # Catch-all handlers for stale task refs
  @impl true
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
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
  end

  defp interrupt_chat(socket) do
    if socket.assigns.chat_task_pid, do: Process.exit(socket.assigns.chat_task_pid, :kill)
    if socket.assigns.chat_task_ref, do: Process.demonitor(socket.assigns.chat_task_ref, [:flush])

    socket
    |> assign(:chat_task_pid, nil)
    |> assign(:chat_token, nil)
    |> assign(:chat_task_ref, nil)
    |> assign(:chat_loading, false)
    |> assign(:chat_streaming_content, "")
    |> assign(:chat_retrieved_context, [])
    |> assign(:embeddings_ready, false)
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
