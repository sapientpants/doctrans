defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Chat
  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Run
  alias DoctransWeb.DocumentLive.{ChatSession, PageViewer, ReprocessModal}
  alias DoctransWeb.ErrorMessages

  import DoctransWeb.DocumentLive.Components,
    only: [status_color: 1, status_text: 1, language_name: 1, processing_progress: 1]

  import DoctransWeb.DocumentLive.ViewerComponents
  import DoctransWeb.DocumentLive.PageViewer, only: [zoom_controls: 1, navigation: 1]
  import DoctransWeb.DocumentLive.ReprocessModal, only: [reprocess_modal: 1, can_reprocess?: 1]
  import DoctransWeb.DocumentLive.ChatComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Documents.get_document(id) do
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

    conversation = Conversations.load(document.id)

    socket =
      socket
      |> assign(:document, document)
      |> assign(:source_available, Run.source_available?(document))
      |> assign(:progress_refresh_pending, false)
      |> assign(:chat_task_pid, nil)
      |> assign(:chat_token, nil)
      |> refresh_progress()
      |> PageViewer.init()
      |> assign(:from, nil)
      |> assign(:search_query, nil)
      |> assign(:search_page, nil)
      |> ReprocessModal.init()
      # Chat state
      |> assign(:chat_open, false)
      |> assign(:chat_loading, false)
      |> assign(:chat_history, conversation.history)
      |> assign(:chat_task_ref, nil)
      |> assign(:chat_last_question, nil)
      |> assign(:chat_stage, nil)
      |> assign(:chat_streaming_content, "")
      |> assign(:chat_retrieved_context, conversation.context)
      |> assign(:chat_interrupted, conversation.interrupted?)
      |> assign(:chat_question, nil)
      |> assign(:embeddings_ready, Chat.embeddings_ready?(document))
      |> stream(:chat_messages, conversation.messages)

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
      when event in ~w(show_reprocess_modal show_document_reprocess_modal hide_reprocess_modal update_reprocess_models reprocess_page reprocess_document) do
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
      |> restore_chat_messages()

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
      user_msg = Conversations.start_question(document.id, trimmed_message)

      socket =
        socket
        |> stream_insert(:chat_messages, user_msg)
        |> assign(:chat_question, user_msg)
        |> assign(:chat_interrupted, false)
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
      chat_token = make_ref()

      task =
        Task.Supervisor.async_nolink(
          Doctrans.TaskSupervisor,
          fn ->
            Chat.Agent.run(
              document,
              trimmed_message,
              chat_history,
              [retrieved_context: retrieved_context],
              fn event -> send(lv, {:chat_event, chat_token, event}) end
            )
          end
        )

      socket =
        socket
        |> assign(:chat_token, chat_token)
        |> assign(:chat_task_ref, task.ref)
        |> assign(:chat_task_pid, task.pid)
        |> assign(:chat_last_question, trimmed_message)

      {:noreply, socket}
    end
  end

  defp restore_chat_messages(%{assigns: %{chat_open: true}} = socket) do
    conversation = Conversations.load(socket.assigns.document.id)

    socket =
      if socket.assigns.chat_loading do
        socket
      else
        socket
        |> assign(:chat_history, conversation.history)
        |> assign(:chat_retrieved_context, conversation.context)
        |> assign(:chat_interrupted, conversation.interrupted?)
      end

    stream(socket, :chat_messages, conversation.messages, reset: true)
  end

  defp restore_chat_messages(socket), do: socket

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

      {:noreply, socket |> prune_chat_context(page) |> maybe_refresh_embeddings_status()}
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

  # Another tab may have reprocessed this page, and its translation may have
  # landed after context was retrieved from the untranslated page. The
  # accumulated context lives in this socket, so a content change has to evict
  # it here too; the next answer would otherwise still be grounded in the text
  # that was just replaced.
  defp prune_chat_context(socket, page) do
    context = Enum.reject(socket.assigns.chat_retrieved_context, &Chat.superseded_by?(&1, page))

    assign(socket, :chat_retrieved_context, context)
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
end
