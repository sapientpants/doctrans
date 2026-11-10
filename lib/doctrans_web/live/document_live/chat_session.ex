defmodule DoctransWeb.DocumentLive.ChatSession do
  @moduledoc """
  Socket state for the document chat panel.

  Owns the chat half of `DoctransWeb.DocumentLive.Show`: every `chat_*` assign,
  the turn task, and the messages that task sends back. `Show` forwards the
  `{:chat_event, _, _}` and `{:chat_flush, _}` messages to `handle_info/2` and
  the `:chat_turn` result to `handle_async/3`, and hands `document_changed/2` and `page_changed/3` what
  `DoctransWeb.DocumentLive.Viewer` answered about a broadcast; nothing else
  writes these assigns. Kept out of the LiveView module so that `Show` handles
  requests and does not reach into the chat state itself.

  A turn runs through `start_async/3` under `Doctrans.TaskSupervisor`. Each turn
  is identified by the token in `:chat_token`, which it carries in every
  streaming event and in its result: `cancel_async/3` kills a task without
  clearing the ref it is tracked under, so a result already in flight can still
  arrive, and LiveView only prunes the exit of a task a later `start_async`
  superseded. A token that no longer matches is a turn that was interrupted,
  whatever it says. `reset_transient/1` clears the token with the rest of the
  turn state, so once a turn has landed nothing it sent can match either.

  Deltas are not rendered one by one. The template runs Markdown and the
  sanitizer over the whole answer so far and ships the result as one dynamic,
  so a render costs the size of the answer, and a model server sends a frame
  per token -- or, if it is broken or hostile, per character. Each delta is
  pushed onto `:chat_pending_content` instead, and the first delta after a flush
  schedules the next `{:chat_flush, token}` message `@flush_interval`
  milliseconds out; that flush folds the buffer into `:chat_streaming_content`,
  which is the assign the template reads. A buffer that is not empty therefore
  always has a flush on its way, and a flush is never scheduled twice. The
  token on the message is what drops a flush that outlives its turn.
  """

  use Gettext, backend: DoctransWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [
      cancel_async: 3,
      put_flash: 3,
      start_async: 4,
      stream: 3,
      stream: 4,
      stream_insert: 3
    ]

  alias Doctrans.Chat
  alias Doctrans.Chat.{Conversations, RetrievedContext}
  alias Doctrans.Validation
  alias DoctransWeb.ErrorMessages

  require Logger

  # The `start_async/3` name of the turn task.
  @turn :chat_turn

  # Milliseconds between two renders of the answer in flight. Long enough that
  # a token-per-frame stream coalesces to a handful of frames per render, short
  # enough that the reader sees the text arrive as it is generated.
  @flush_interval 50

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
    |> assign(:chat_pending_content, [])
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

  A question over `Doctrans.Validation.max_chat_question_chars/0`, or over
  its byte bound, is refused with a flash and never reaches the database or
  the model: the question is saved before generation, so the bound has to
  hold here, ahead of `Conversations.start_question/2`. A blank question is
  ignored without comment, as it always was, and so is one that is not a
  string: the form never sends one, so there is no reader to tell.

  Runs the agentic pipeline off-process. Stage and token events are sent back to
  the LiveView as `{:chat_event, token, event}` messages; the task's result
  carries the final answer and the Retrieved context for the next turn.
  """
  def ask(socket, message) do
    case Validation.validate_chat_question(message) do
      {:ok, _question} when socket.assigns.chat_loading -> socket
      {:ok, question} -> start_turn(socket, question)
      {:error, reason} when reason in [:empty_question, :invalid_question] -> socket
      {:error, reason} -> put_flash(socket, :error, ErrorMessages.message(reason))
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
    |> assign(:chat_pending_content, [])
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
  Applies a streaming event from the turn in flight, or the flush that renders
  its buffered deltas; either from any other turn is dropped.
  """
  def handle_info({:chat_event, token, event}, socket) do
    {:noreply, if(current_turn?(socket, token), do: apply_event(socket, event), else: socket)}
  end

  def handle_info({:chat_flush, token}, socket) do
    {:noreply, if(current_turn?(socket, token), do: flush_pending(socket), else: socket)}
  end

  # Whether a token belongs to the turn in flight. A landed turn's token is
  # `nil`, which no message ever carries.
  defp current_turn?(socket, token), do: token == socket.assigns.chat_token

  defp apply_event(socket, {:stage, stage}), do: assign(socket, :chat_stage, stage)

  # The buffer is kept in reverse, so a delta is a cons and the flush one
  # reverse. A flush is scheduled when the buffer was empty and nothing else:
  # a non-empty buffer already has one coming.
  defp apply_event(socket, {:delta, text}) do
    case socket.assigns.chat_pending_content do
      [] ->
        Process.send_after(self(), {:chat_flush, socket.assigns.chat_token}, @flush_interval)
        assign(socket, :chat_pending_content, [text])

      pending ->
        assign(socket, :chat_pending_content, [text | pending])
    end
  end

  defp flush_pending(socket) do
    pending = socket.assigns.chat_pending_content

    content =
      IO.iodata_to_binary([socket.assigns.chat_streaming_content | Enum.reverse(pending)])

    socket
    |> assign(:chat_streaming_content, content)
    |> assign(:chat_pending_content, [])
  end

  @doc """
  Lands the turn task's result.

  A result whose token is not the current one, and an exit while no turn is
  running, both belong to a turn `interrupt/1` already stopped and are dropped.
  An exit during a turn is the task crashing, which the pipeline's own error
  handling did not turn into an `{:error, _}` result, so it is reported as a
  failure the catalog cannot name.
  """
  def handle_async(@turn, {:ok, {token, result}}, socket) do
    {:noreply, if(current_turn?(socket, token), do: land(socket, result), else: socket)}
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
  Reacts to what a document broadcast changed, as `Viewer.document_updated/2`
  or `Viewer.document_deleted/1` answered it: a run replaced or a document
  gone stops the turn in flight; anything else is no concern of the chat's.
  """
  @spec document_changed(
          Phoenix.LiveView.Socket.t(),
          DoctransWeb.DocumentLive.Viewer.document_change()
        ) ::
          Phoenix.LiveView.Socket.t()
  def document_changed(socket, change) when change in [:run_replaced, :vanished],
    do: interrupt(socket)

  def document_changed(socket, :changed), do: socket

  @doc """
  Reacts to a page broadcast, as `Viewer.page_updated/2` placed it: a page of
  this document, on screen or not, may have superseded Retrieved context and
  may have made the document searchable; a foreign page changes nothing.
  """
  @spec page_changed(
          Phoenix.LiveView.Socket.t(),
          DoctransWeb.DocumentLive.Viewer.page_change(),
          Doctrans.Documents.Page.t()
        ) :: Phoenix.LiveView.Socket.t()
  def page_changed(socket, :foreign, _page), do: socket

  def page_changed(socket, _change, page),
    do: socket |> prune_context(page) |> refresh_embeddings_status()

  @doc """
  Stops the turn in flight, if there is one, and drops the Retrieved context.

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
    |> assign(:chat_retrieved_context, RetrievedContext.new())
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
  Drops Retrieved context superseded by a page that has just changed.

  Another tab may have reprocessed this page, and its translation may have
  landed after context was retrieved from the untranslated page. The context
  lives in this socket between turns, so a content change has to evict it here
  too; the next answer would otherwise still be grounded in the text that was
  just replaced.
  """
  def prune_context(socket, page) do
    context = RetrievedContext.current_against(socket.assigns.chat_retrieved_context, page)

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
    case put_error(socket, failure_message(reason)) do
      {:ok, socket} ->
        socket

      {:error, save_reason} ->
        Logger.warning("Chat error message not saved: #{inspect(save_reason, limit: 10)}")
        socket |> reset_transient() |> assign(:chat_interrupted, true)
    end
  end

  # An answer the row refused -- one over `Doctrans.Chat.Message.max_content_bytes/0`,
  # which only a misbehaving model server produces -- is apologised for in the
  # chat's own voice: the catalog's entry for a refused write speaks of a
  # document that could not be saved, and this is not one.
  defp failure_message({:validation_failed, _bindings}), do: apology()
  defp failure_message(reason), do: ErrorMessages.message(reason, apology())

  defp apology, do: gettext("Sorry, I encountered an error. Please try again.")

  @doc """
  Applies a successful chat response to the socket.

  Inserts the assistant message, resets the transient streaming assigns, appends
  the exchange to the capped history, and keeps the Retrieved context for the
  next turn.

  A page reprocessed while the answer was generating leaves obsolete passages in
  the returned context. `Conversations.finish/5` checks the context under the
  document lock, which is what fences a concurrent reset, and hands back what it
  saved; the socket keeps that, so it never holds passages the database already
  dropped.
  """
  def put_response(socket, response, retrieved_context) do
    with {:ok, assistant_msg, saved_context} <-
           Conversations.finish(
             socket.assigns.chat_question,
             "assistant",
             response,
             retrieved_context,
             socket.assigns.document
           ) do
      {:ok, apply_response(socket, assistant_msg, response, saved_context)}
    end
  end

  defp apply_response(socket, assistant_msg, response, retrieved_context) do
    updated_history =
      (socket.assigns.chat_history ++
         [
           %{role: "user", content: socket.assigns.chat_last_question},
           %{role: "assistant", content: response}
         ])
      |> Enum.take(-Chat.history_limit())

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
    with {:ok, error_msg, _context} <-
           Conversations.finish(
             socket.assigns.chat_question,
             "error",
             message,
             RetrievedContext.new()
           ) do
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
    |> assign(:chat_pending_content, [])
  end
end
