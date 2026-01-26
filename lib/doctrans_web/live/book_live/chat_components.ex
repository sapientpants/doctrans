defmodule DoctransWeb.DocumentLive.ChatComponents do
  @moduledoc "Components for the document chat panel."
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [render_markdown: 1]

  attr :chat_messages, :any, required: true
  attr :chat_loading, :boolean, required: true
  attr :embeddings_ready, :boolean, required: true

  def chat_panel(assigns) do
    ~H"""
    <div class="w-80 border-l border-base-300 flex flex-col bg-base-100 flex-shrink-0">
      <%!-- Header --%>
      <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between bg-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 text-primary" />
          <h3 class="font-semibold text-sm">{gettext("Chat")}</h3>
        </div>
        <button
          type="button"
          phx-click="toggle_chat"
          class="btn btn-ghost btn-xs btn-circle"
          title={gettext("Close chat")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Messages area --%>
      <div
        id="chat-messages"
        phx-update="stream"
        class="flex-1 overflow-y-auto p-3 space-y-3"
        phx-hook="ScrollToBottom"
      >
        <%!-- Empty state - shown when no messages --%>
        <div
          id="chat-empty-state"
          class="hidden only:flex flex-col items-center justify-center h-full text-base-content/50 px-4"
        >
          <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 mb-3" />
          <p class="text-sm text-center">{gettext("Ask questions about this document")}</p>
          <p class="text-xs text-center mt-2 text-base-content/40">
            {gettext("I'll find relevant content and answer based on it.")}
          </p>
        </div>
        <%!-- Messages --%>
        <div :for={{id, msg} <- @chat_messages} id={id}>
          <.chat_message message={msg} />
        </div>
      </div>

      <%!-- Loading indicator --%>
      <div :if={@chat_loading} class="px-3 py-2 border-t border-base-300 bg-base-200/50">
        <div class="flex items-center gap-2 text-sm text-base-content/70">
          <span class="loading loading-dots loading-sm"></span>
          <span>{gettext("Thinking...")}</span>
        </div>
      </div>

      <%!-- Not ready state --%>
      <div
        :if={!@embeddings_ready}
        class="px-3 py-2 border-t border-base-300 bg-warning/10 text-warning-content"
      >
        <div class="flex items-center gap-2 text-xs">
          <.icon name="hero-clock" class="w-4 h-4 text-warning" />
          <span>{gettext("Document is still being processed. Chat will be available soon.")}</span>
        </div>
      </div>

      <%!-- Input form --%>
      <form
        :if={@embeddings_ready}
        phx-submit="send_chat_message"
        class="p-3 border-t border-base-300"
        id="chat-form"
      >
        <div class="flex gap-2">
          <input
            type="text"
            name="message"
            placeholder={gettext("Ask a question...")}
            class="input input-bordered input-sm flex-1 text-sm"
            disabled={@chat_loading}
            autocomplete="off"
            id="chat-input"
          />
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={@chat_loading}
            title={gettext("Send message")}
          >
            <.icon name="hero-paper-airplane" class="w-4 h-4" />
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :message, :map, required: true

  def chat_message(assigns) do
    ~H"""
    <div class={[
      "max-w-[95%] rounded-lg p-2.5 text-sm",
      @message.role == "user" && "bg-primary/10 ml-auto",
      @message.role == "assistant" && "bg-base-200",
      @message.role == "error" && "bg-error/10 text-error"
    ]}>
      <div :if={@message.role == "user"} class="text-right">
        {@message.content}
      </div>
      <div :if={@message.role == "assistant"} class="prose prose-sm max-w-none">
        <.markdown_content content={@message.content} />
      </div>
      <div :if={@message.role == "error"} class="flex items-center gap-2">
        <.icon name="hero-exclamation-triangle" class="w-4 h-4 flex-shrink-0" />
        <span>{@message.content}</span>
      </div>
    </div>
    """
  end

  attr :content, :string, default: nil

  defp markdown_content(assigns) do
    html = render_markdown(assigns.content || "")
    assigns = assign(assigns, :html, html)
    ~H"<div>{raw(@html)}</div>"
  end
end
