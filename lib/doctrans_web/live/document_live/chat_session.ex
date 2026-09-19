defmodule DoctransWeb.DocumentLive.ChatSession do
  @moduledoc """
  Socket state for the document chat panel.

  Owns the chat half of `DoctransWeb.DocumentLive.Show`: opening and restoring
  the panel, starting a turn, and applying a turn's success and error outcomes
  to the socket — inserting messages into the `:chat_messages` stream, resetting
  the transient streaming/progress assigns, and updating the accumulated history
  and retrieval context. Kept out of the LiveView module so that `Show` handles
  requests and does not reach into the chat contexts itself.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 3, stream: 4, stream_insert: 3]

  alias Doctrans.Chat
  alias Doctrans.Chat.Conversations
  alias DoctransWeb.ErrorMessages

  # Keep the last 8 exchanges (user + assistant) as history for future turns.
  @history_limit 16

  @doc """
  Assigns the initial chat state for a freshly mounted document.
  """
  def init(socket, document) do
    conversation = Conversations.load(document.id)

    socket
    |> assign(:chat_open, false)
    |> assign(:chat_loading, false)
    |> assign(:chat_history, conversation.history)
    |> assign(:chat_task_ref, nil)
    |> assign(:chat_task_pid, nil)
    |> assign(:chat_token, nil)
    |> assign(:chat_last_question, nil)
    |> assign(:chat_stage, nil)
    |> assign(:chat_streaming_content, "")
    |> assign(:chat_retrieved_context, conversation.context)
    |> assign(:chat_interrupted, conversation.interrupted?)
    |> assign(:chat_question, nil)
    |> assign(:embeddings_ready, Chat.embeddings_ready?(document))
    |> stream(:chat_messages, conversation.messages)
  end

  @doc """
  Opens or closes the panel, refreshing its contents when it becomes visible.
  """
  def toggle_open(socket) do
    socket
    |> assign(:chat_open, !socket.assigns.chat_open)
    |> refresh_embeddings_status()
    |> restore_messages()
  end

  @doc """
  Starts a chat turn, unless the question is blank or a turn is already running.

  Spawns the agentic pipeline off-process. Stage and token events are relayed to
  the calling LiveView via `on_event`; the task's return value carries the final
  answer and the updated context for history and accumulation.
  """
  def ask(socket, message) do
    question = String.trim(message || "")

    if question == "" or socket.assigns.chat_loading do
      socket
    else
      start_turn(socket, question)
    end
  end

  defp start_turn(socket, question) do
    document = socket.assigns.document
    user_msg = Conversations.start_question(document.id, question)
    chat_token = make_ref()
    lv = self()

    task =
      Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
        Chat.Agent.run(
          document,
          question,
          socket.assigns.chat_history,
          [retrieved_context: socket.assigns.chat_retrieved_context],
          fn event -> send(lv, {:chat_event, chat_token, event}) end
        )
      end)

    socket
    |> stream_insert(:chat_messages, user_msg)
    |> assign(:chat_question, user_msg)
    |> assign(:chat_interrupted, false)
    |> assign(:chat_loading, true)
    |> assign(:chat_stage, :understanding)
    |> assign(:chat_streaming_content, "")
    |> assign(:chat_token, chat_token)
    |> assign(:chat_task_ref, task.ref)
    |> assign(:chat_task_pid, task.pid)
    |> assign(:chat_last_question, question)
  end

  @doc """
  Re-reads the saved conversation while the panel is open.

  A turn in flight owns the socket's history and context, so only the message
  stream is refreshed until it lands.
  """
  def restore_messages(%{assigns: %{chat_open: true}} = socket) do
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

  def restore_messages(socket), do: socket

  @doc """
  Re-checks whether the document is searchable, while the panel is open.
  """
  def refresh_embeddings_status(%{assigns: %{chat_open: true}} = socket) do
    assign(socket, :embeddings_ready, Chat.embeddings_ready?(socket.assigns.document))
  end

  def refresh_embeddings_status(socket), do: socket

  @doc """
  Drops accumulated context superseded by a page that has just changed.

  Another tab may have reprocessed this page, and its translation may have
  landed after context was retrieved from the untranslated page. The accumulated
  context lives in this socket, so a content change has to evict it here too;
  the next answer would otherwise still be grounded in the text that was just
  replaced.
  """
  def prune_context(socket, page) do
    context = Enum.reject(socket.assigns.chat_retrieved_context, &Chat.superseded_by?(&1, page))

    assign(socket, :chat_retrieved_context, context)
  end

  @doc """
  Applies a failed chat turn to the socket, rendering `reason` for the reader.
  """
  def put_failure(socket, reason) do
    put_error(socket, ErrorMessages.message(reason))
  end

  @doc """
  Applies a successful chat response to the socket.

  Inserts the assistant message, resets the transient streaming assigns, appends
  the exchange to the capped history, and stores the accumulated retrieval
  context for the next turn.

  A page reprocessed while the answer was generating leaves obsolete chunks in
  the returned context, so it is filtered before it is both saved and kept for
  the next turn; the socket would otherwise hold chunks the database already
  dropped. `Conversations.finish/5` filters again under the document lock, which
  is what actually fences a concurrent reset — this pass only keeps the socket
  and the saved session in agreement.
  """
  def put_response(socket, response, retrieved_context) do
    context = Chat.current_context(retrieved_context)

    with {:ok, assistant_msg} <-
           Conversations.finish(
             socket.assigns.chat_question,
             "assistant",
             response,
             context,
             socket.assigns.document
           ) do
      {:ok, apply_response(socket, assistant_msg, response, context)}
    end
  end

  defp apply_response(socket, assistant_msg, response, retrieved_context) do
    updated_history =
      (socket.assigns.chat_history ++
         [
           %{role: "user", content: socket.assigns.chat_last_question},
           %{role: "assistant", content: response}
         ])
      |> Enum.take(-@history_limit)

    socket
    |> stream_insert(:chat_messages, assistant_msg)
    |> reset_transient()
    |> assign(:chat_history, updated_history)
    |> assign(:chat_retrieved_context, retrieved_context)
  end

  @doc """
  Applies an error outcome to the socket, inserting an error message and
  resetting the transient streaming assigns.
  """
  def put_error(socket, message) do
    {:ok, error_msg} = Conversations.finish(socket.assigns.chat_question, "error", message, [])

    socket
    |> stream_insert(:chat_messages, error_msg)
    |> reset_transient()
  end

  defp reset_transient(socket) do
    socket
    |> assign(:chat_question, nil)
    |> assign(:chat_loading, false)
    |> assign(:chat_task_ref, nil)
    |> assign(:chat_last_question, nil)
    |> assign(:chat_stage, nil)
    |> assign(:chat_streaming_content, "")
  end
end
