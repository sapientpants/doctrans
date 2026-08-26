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

  use Gettext, backend: DoctransWeb.Gettext

  # Keep the last 8 exchanges (user + assistant) as history for future turns.
  @history_limit 16

  @doc """
  Applies a successful chat response to the socket.

  Inserts the assistant message, resets the transient streaming assigns, appends
  the exchange to the capped history, and stores the accumulated retrieval
  context for the next turn.
  """
  def put_response(socket, response, retrieved_context) do
    assistant_msg = message(:assistant, response)

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
    socket
    |> stream_insert(:chat_messages, message(:error, message))
    |> reset_transient()
  end

  @doc "Maps a failure reason to a user-facing, translated error message."
  def error_message(:empty_question), do: gettext("Please enter a question.")

  def error_message({:database_error, _}),
    do: gettext("Failed to search the document. Please try again.")

  def error_message(_), do: gettext("Sorry, I encountered an error. Please try again.")

  defp reset_transient(socket) do
    socket
    |> assign(:chat_loading, false)
    |> assign(:chat_task_ref, nil)
    |> assign(:chat_last_question, nil)
    |> assign(:chat_stage, nil)
    |> assign(:chat_streaming_content, "")
  end

  defp message(role, content) do
    %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: to_string(role),
      content: content
    }
  end
end
