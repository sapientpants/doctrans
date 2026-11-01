defmodule DoctransWeb.DocumentLive.ChatSession do
  @moduledoc """
  Socket state for the document chat panel.

  Owns the chat half of `DoctransWeb.DocumentLive.Show`: every `chat_*` assign,
  the turn task, and the messages that task sends back. `Show` forwards the
  `{:chat_event, _, _}` messages to `handle_info/2` and the `:chat_turn` result
  to `handle_async/3`, and calls `interrupt/1` when the document under the
  conversation changes; nothing else writes these assigns. Kept out of the
  LiveView module so that `Show` handles requests and does not reach into the
  chat contexts itself.

  A turn runs through `start_async/3` under `Doctrans.TaskSupervisor`. Each turn
  is identified by the token in `:chat_token`, which it carries in every
  streaming event and in its result: `cancel_async/3` kills a task without
  clearing the ref it is tracked under, so a result already in flight can still
  arrive, and LiveView only prunes the exit of a task a later `start_async`
  superseded. A token that no longer matches is a turn that was interrupted,
  whatever it says. `reset_transient/1` clears the token with the rest of the
  turn state, so once a turn has landed nothing it sent can match either.
  """

  use Gettext, backend: DoctransWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [cancel_async: 3, start_async: 4, stream: 3, stream: 4, stream_insert: 3]

  alias Doctrans.Chat
  alias Doctrans.Chat.Conversations
  alias DoctransWeb.ErrorMessages

  require Logger

  # Keep the last 8 exchanges (user + assistant) as history for future turns.
  @history_limit 16

  # The `start_async/3` name of the turn task.
  @turn :chat_turn

  @doc """
  Assigns the initial chat state for a freshly mounted document.
  """
  def init(socket, document) do
    conversation = Conversations.load(document.id)

    socket
    |> assign(:chat_open, false)
    |> assign(:chat_loading, false)
    |> assign(:chat_history, conversation.history)
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

  Runs the agentic pipeline off-process. Stage and token events are sent back to
  the LiveView as `{:chat_event, token, event}` messages; the task's result
  carries the final answer and the updated context for history and accumulation.
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
    history = socket.assigns.chat_history
    context = socket.assigns.chat_retrieved_context
    user_msg = Conversations.start_question(document.id, question)
    token = make_ref()
    lv = self()

    socket
    |> stream_insert(:chat_messages, user_msg)
    |> assign(:chat_question, user_msg)
    |> assign(:chat_interrupted, false)
    |> assign(:chat_loading, true)
    |> assign(:chat_stage, :understanding)
    |> assign(:chat_streaming_content, "")
    |> assign(:chat_token, token)
    |> assign(:chat_last_question, question)
    |> start_async(
      @turn,
      fn ->
        result =
          Chat.Agent.run(
            document,
            question,
            history,
            [retrieved_context: context],
            fn event -> send(lv, {:chat_event, token, event}) end
          )

        {token, result}
      end,
      supervisor: Doctrans.TaskSupervisor
    )
  end

  @doc """
  Applies a streaming event from the turn in flight; one from any other turn is
  dropped.
  """
  def handle_info({:chat_event, token, event}, socket) do
    if token == socket.assigns.chat_token,
      do: {:noreply, apply_event(socket, event)},
      else: {:noreply, socket}
  end

  defp apply_event(socket, {:stage, stage}), do: assign(socket, :chat_stage, stage)

  defp apply_event(socket, {:delta, text}),
    do: assign(socket, :chat_streaming_content, socket.assigns.chat_streaming_content <> text)

  @doc """
  Lands the turn task's result.

  A result whose token is not the current one, and an exit while no turn is
  running, both belong to a turn `interrupt/1` already stopped and are dropped.
  An exit during a turn is the task crashing, which the pipeline's own error
  handling did not turn into an `{:error, _}` result, so it is reported as a
  failure the catalog cannot name.
  """
  def handle_async(@turn, {:ok, {token, result}}, socket) do
    if token == socket.assigns.chat_token,
      do: {:noreply, land(socket, result)},
      else: {:noreply, socket}
  end

  def handle_async(@turn, {:exit, _reason}, %{assigns: %{chat_token: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_async(@turn, {:exit, reason}, socket) do
    # Bounded: an exit reason carries a stacktrace whose frames can hold the
    # question, the history and the retrieved context.
    Logger.warning("Chat turn exited: #{inspect(reason, limit: 10, printable_limit: 256)}")
    {:noreply, put_failure(socket, :unknown)}
  end

  defp land(socket, {:ok, response, retrieved_context}) do
    case put_response(socket, response, retrieved_context) do
      {:ok, socket} -> socket
      {:error, :obsolete_run} -> interrupt(socket)
      {:error, reason} -> put_failure(socket, reason)
    end
  end

  defp land(socket, {:error, reason}), do: put_failure(socket, reason)

  @doc """
  Stops the turn in flight, if there is one, and drops the accumulated context.

  For a document that has gone or been replaced underneath the conversation.
  The turn has to be stopped here rather than when its result lands:
  `Doctrans.Processing.Cancellation.cancel_jobs/1` cancels Oban jobs and never
  reaches a task this LiveView spawned, so left alone it runs the whole agent
  pipeline -- several LLM calls, up to a 300s receive timeout each -- to produce
  an answer with nowhere to go. Every landing a turn has writes through
  `Doctrans.Chat.Conversations`, whose chat session cascaded away with the
  document or belongs to a run that is no longer current, so the answer could
  not be saved in any case.

  Killed, not shut down: the task does not trap exits, but a `:kill` reaches it
  inside whatever receive it is parked in, with no cooperation needed. Clearing
  the token with the rest of the turn state is what lets a result or exit that
  was already in flight be dropped by `handle_async/3`.
  """
  def interrupt(socket) do
    socket
    |> cancel_async(@turn, :kill)
    |> reset_transient()
    |> assign(:chat_retrieved_context, [])
    |> assign(:embeddings_ready, false)
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

  The assistant answers in the first person, so a failure the catalog cannot
  name is its own apology here, not the neutral fallback every flash shares.

  When the error message itself cannot be saved, the turn still ends: the
  question is on record with no answer, which is exactly what the interrupted
  notice describes, so that is what the panel shows.
  """
  def put_failure(socket, reason) do
    case put_error(socket, ErrorMessages.message(reason, apology())) do
      {:ok, socket} ->
        socket

      {:error, save_reason} ->
        Logger.warning("Chat error message not saved: #{inspect(save_reason, limit: 10)}")
        socket |> reset_transient() |> assign(:chat_interrupted, true)
    end
  end

  defp apology, do: gettext("Sorry, I encountered an error. Please try again.")

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

  Returns `{:error, reason}` when the message could not be saved, leaving the
  socket untouched, in the same shape as `put_response/3`.
  """
  def put_error(socket, message) do
    with {:ok, error_msg} <-
           Conversations.finish(socket.assigns.chat_question, "error", message, []) do
      {:ok, socket |> stream_insert(:chat_messages, error_msg) |> reset_transient()}
    end
  end

  # Everything a turn sets while it runs. The token goes with the rest: it is
  # what `handle_info/2` and `handle_async/3` match a message against, so a
  # landed turn's late messages match nothing.
  defp reset_transient(socket) do
    socket
    |> assign(:chat_question, nil)
    |> assign(:chat_loading, false)
    |> assign(:chat_token, nil)
    |> assign(:chat_last_question, nil)
    |> assign(:chat_stage, nil)
    |> assign(:chat_streaming_content, "")
  end
end
