defmodule DoctransWeb.DocumentLive.ChatSession do
  @moduledoc """
  Socket state transitions for the document chat panel.

  Encapsulates how a chat turn's success and error outcomes are applied to the
  LiveView socket: inserting the resulting message into the `:chat_messages`
  stream, resetting the transient streaming/progress assigns, and updating the
  accumulated history and retrieval context. Kept out of the LiveView module to
  keep `DoctransWeb.DocumentLive.Show` focused on request handling.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream_insert: 3]

  alias Doctrans.Chat.Conversations

  # Keep the last 8 exchanges (user + assistant) as history for future turns.
  @history_limit 16

  @doc """
  Applies a successful chat response to the socket.

  Inserts the assistant message, resets the transient streaming assigns, appends
  the exchange to the capped history, and stores the accumulated retrieval
  context for the next turn.
  """
  def put_response(socket, response, retrieved_context) do
    {:ok, assistant_msg} =
      Conversations.finish(socket.assigns.chat_question, "assistant", response, retrieved_context)

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
