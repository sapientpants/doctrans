defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Chat
  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias DoctransWeb.DocumentLive.{ChatSession, PageViewer, ReprocessModal}
  alias DoctransWeb.ErrorMessages

  import DoctransWeb.DocumentLive.Components,
    only: [status_color: 1, status_text: 1, language_name: 1]

  import DoctransWeb.DocumentLive.ViewerComponents
  import DoctransWeb.DocumentLive.PageViewer, only: [zoom_controls: 1, navigation: 1]
  import DoctransWeb.DocumentLive.ReprocessModal, only: [reprocess_modal: 1, can_reprocess?: 1]
  import DoctransWeb.DocumentLive.ChatComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Documents.get_document_with_pages(id) do
      nil -> {:ok, assign(socket, :document, nil)}
      document -> mount_document(socket, document)
    end
  end

  defp mount_document(socket, document) do
    _ =
      if connected?(socket) do
        _ = Topics.subscribe_document(document.id)
      else
        :ok
      end

    socket =
      socket
      |> assign(:document, document)
      |> PageViewer.init()
      |> assign(:from, nil)
      |> assign(:search_query, nil)
      |> assign(:search_page, nil)
      |> ReprocessModal.init()
      # Chat state
      |> assign(:chat_open, false)
      |> assign(:chat_loading, false)
      |> assign(:chat_history, [])
      |> assign(:chat_task_ref, nil)
      |> assign(:chat_last_question, nil)
      |> assign(:chat_stage, nil)
      |> assign(:chat_streaming_content, "")
      |> assign(:chat_retrieved_context, [])
      |> assign(:embeddings_ready, Chat.embeddings_ready?(document))
      |> stream(:chat_messages, [])

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

  def handle_event(event, params, socket)
      when event in ~w(prev_page next_page goto_page toggle_original zoom_in zoom_out) do
    PageViewer.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in ~w(show_reprocess_modal hide_reprocess_modal update_reprocess_models reprocess_page) do
    ReprocessModal.handle_event(event, params, socket)
  end

  # Chat event handlers

  @impl true
  def handle_event("toggle_chat", _params, socket) do
    socket =
      socket
      |> assign(:chat_open, !socket.assigns.chat_open)
      # Refresh embeddings status when opening chat
      |> maybe_refresh_embeddings_status()

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_chat_message", %{"message" => message}, socket) do
    trimmed_message = String.trim(message || "")

    # Guard against empty messages and double submits
    if trimmed_message == "" or socket.assigns.chat_loading do
      {:noreply, socket}
    else
      document = socket.assigns.document

      # Add user message to stream
      user_msg = %{
        id: "msg-#{System.unique_integer([:positive])}",
        role: "user",
        content: trimmed_message
      }

      socket =
        socket
        |> stream_insert(:chat_messages, user_msg)
        |> assign(:chat_loading, true)
        |> assign(:chat_stage, :understanding)
        |> assign(:chat_streaming_content, "")

      # Get existing chat history and accumulated retrieval context
      chat_history = socket.assigns.chat_history
      retrieved_context = socket.assigns.chat_retrieved_context

      # Spawn async task running the agentic pipeline. Stage/token events are
      # sent back to this LiveView process via the on_event callback; the task's
      # return value carries the final answer + updated context for history and
      # accumulation.
      lv = self()

      task =
        Task.Supervisor.async_nolink(
          Doctrans.TaskSupervisor,
          fn ->
            Chat.Agent.run(
              document,
              trimmed_message,
              chat_history,
              [retrieved_context: retrieved_context],
              fn event -> send(lv, {:chat_event, event}) end
            )
          end
        )

      socket =
        socket
        |> assign(:chat_task_ref, task.ref)
        |> assign(:chat_last_question, trimmed_message)

      {:noreply, socket}
    end
  end

  defp maybe_refresh_embeddings_status(socket) do
    if socket.assigns.chat_open do
      assign(socket, :embeddings_ready, Chat.embeddings_ready?(socket.assigns.document))
    else
      socket
    end
  end

  # PubSub Handlers

  @impl true
  def terminate(_reason, socket) do
    if connected?(socket) && socket.assigns.document do
      Topics.unsubscribe_document(socket.assigns.document.id)
    end

    :ok
  end

  @impl true
  def handle_info(:fetch_available_models, socket) do
    ReprocessModal.fetch_available_models(socket)
  end

  @impl true
  def handle_info({:document_updated, document}, socket) do
    {:noreply, assign(socket, :document, document)}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    # Ignore updates for other documents (the socket is subscribed to one).
    if page.document_id != socket.assigns.document.id do
      {:noreply, socket}
    else
      # Update the current page in place. No re-query of the document and its
      # full page list is needed; document-level fields (title, status,
      # total_pages) are kept fresh via :document_updated broadcasts.
      socket =
        if socket.assigns.current_page && socket.assigns.current_page.id == page.id do
          assign(socket, :current_page, page)
        else
          socket
        end

      {:noreply, maybe_refresh_embeddings_status(socket)}
    end
  end

  # Chat streaming/progress events from the agent pipeline

  @impl true
  def handle_info({:chat_event, {:stage, stage}}, socket) do
    {:noreply, assign(socket, :chat_stage, stage)}
  end

  @impl true
  def handle_info({:chat_event, {:delta, text}}, socket) do
    {:noreply,
     assign(socket, :chat_streaming_content, socket.assigns.chat_streaming_content <> text)}
  end

  # Chat response handlers (async_nolink pattern)

  @impl true
  def handle_info({ref, {:ok, response, retrieved_context}}, socket)
      when socket.assigns.chat_task_ref == ref do
    # Flush the :DOWN message
    Process.demonitor(ref, [:flush])
    {:noreply, ChatSession.put_response(socket, response, retrieved_context)}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) when socket.assigns.chat_task_ref == ref do
    Process.demonitor(ref, [:flush])
    {:noreply, ChatSession.put_error(socket, ErrorMessages.message(reason))}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when socket.assigns.chat_task_ref == ref do
    # :normal = success (result already handled); only error on crashes
    if reason == :normal,
      do: {:noreply, socket},
      else: {:noreply, ChatSession.put_error(socket, ErrorMessages.message(:unknown))}
  end

  # Catch-all handlers for stale task refs
  @impl true
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
end
