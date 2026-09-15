defmodule DoctransWeb.DocumentLive.ChatComponents do
  @moduledoc "Components for the document chat panel."
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [render_markdown: 2]

  attr :chat_messages, :any, required: true
  attr :chat_interrupted, :boolean, default: false
  attr :chat_loading, :boolean, required: true
  attr :chat_stage, :atom, default: nil
  attr :chat_streaming_content, :string, default: ""
  attr :embeddings_ready, :boolean, required: true

  def chat_panel(assigns) do
    ~H"""
    <%!-- Below `lg` the panel has nowhere to sit in flow -- a fixed 320px third
         column does not fit a narrow viewport -- so it becomes an overlay
         pinned to the right edge, with a backdrop that dismisses it. From `lg`
         up both revert to the in-flow sidebar.

         z-30/z-40 is deliberate: it clears the page viewer's sticky footer
         (`z-10`) while staying under the flash toasts and the reprocess dialog
         (both `z-50`) and the daisyUI upload modal (`z-999`), so an open dialog
         still renders above the chat.

         It is *not* `role="dialog" aria-modal="true"`: `ChatInput` refuses to
         take focus while such a dialog is open, and the chat input has to keep
         being refocused after every answer. An `<aside>` with a name gives it a
         landmark instead. --%>
    <div
      id="chat-backdrop"
      class="fixed inset-0 z-30 bg-black/40 lg:hidden"
      phx-click="toggle_chat"
      aria-hidden="true"
    >
    </div>
    <aside
      id="chat-panel"
      aria-label={gettext("Chat")}
      class="fixed inset-y-0 right-0 z-40 flex w-full max-w-sm flex-col bg-base-100 shadow-xl lg:static lg:z-auto lg:w-80 lg:max-w-none lg:flex-shrink-0 lg:border-l lg:border-base-300 lg:shadow-none"
    >
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
          aria-label={gettext("Close chat")}
          title={gettext("Close chat")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <p id="chat-retention-note" class="px-4 py-2 text-xs text-base-content/60">
        {gettext("Chat is saved on this device. The latest 100 messages are kept per document.")}
      </p>
      <p
        :if={@chat_interrupted}
        id="chat-interrupted"
        role="status"
        class="px-4 py-2 text-xs text-warning"
      >
        {gettext("The last question has no saved answer. Send it again to retry.")}
      </p>

      <%!-- Messages area: the scroll container plus the "new messages"
           affordance floating over its bottom edge. --%>
      <div class="relative flex flex-1 flex-col min-h-0">
        <div
          id="chat-scroll"
          class="flex-1 min-h-0 overflow-y-auto p-3 space-y-3"
          phx-hook="ChatScroll"
        >
          <%!-- Finalized messages (managed by LiveView streams) --%>
          <div id="chat-messages" phx-update="stream" class="space-y-3">
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

          <%!-- Live streaming answer, shown outside the stream until finalized. Must
               be a sibling of (not inside) the phx-update="stream" container, or
               LiveView will not remove it when it is cleared, doubling the answer. --%>
          <div
            :if={@chat_streaming_content != ""}
            id="chat-streaming"
            class="max-w-[95%] rounded-lg p-2.5 text-sm bg-base-200"
          >
            <div class="markdown markdown-sm">
              <.markdown_content content={@chat_streaming_content} />
            </div>
          </div>
        </div>

        <%!-- Shown by the `ChatScroll` hook when an answer arrives while the
             reader is scrolled up, so following along stays their choice.
             `phx-update="ignore"` keeps a later patch from re-hiding it: whether
             it is visible is client state that no assign knows about. --%>
        <div
          id="chat-new-messages"
          phx-update="ignore"
          class="hidden absolute bottom-3 right-3 z-10"
        >
          <button
            id="chat-jump-to-latest"
            type="button"
            class="btn btn-primary btn-xs gap-1 rounded-full shadow-lg transition-transform hover:scale-105"
            title={gettext("New messages")}
          >
            <.icon name="hero-arrow-down" class="w-3.5 h-3.5" />
            {gettext("New messages")}
          </button>
        </div>
      </div>

      <%!-- Loading indicator - shown while working, hidden once tokens stream in --%>
      <div
        :if={@chat_loading and @chat_streaming_content == ""}
        class="px-3 py-2 border-t border-base-300 bg-base-200/50"
      >
        <div class="flex items-center gap-2 text-sm text-base-content/70">
          <span class="loading loading-dots loading-sm"></span>
          <span>{stage_label(@chat_stage)}</span>
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
        <label for="chat-input" class="sr-only">
          {gettext("Ask a question about this document")}
        </label>
        <div class="flex gap-2">
          <input
            type="text"
            name="message"
            placeholder={gettext("Ask a question...")}
            class="input input-bordered input-sm flex-1 text-sm"
            disabled={@chat_loading}
            autocomplete="off"
            id="chat-input"
            phx-hook="ChatInput"
          />
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={@chat_loading}
            aria-label={gettext("Send message")}
            title={gettext("Send message")}
          >
            <.icon name="hero-paper-airplane" class="w-4 h-4" />
          </button>
        </div>
      </form>
    </aside>
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
      <div :if={@message.role == "assistant"} class="markdown markdown-sm">
        <.markdown_content content={@message.content} />
      </div>
      <div :if={@message.role == "error"} class="flex items-center gap-2">
        <.icon name="hero-exclamation-triangle" class="w-4 h-4 flex-shrink-0" />
        <span>{@message.content}</span>
      </div>
    </div>
    """
  end

  # Stage-aware status text shown in the loading indicator.
  defp stage_label(:understanding), do: gettext("Understanding your question...")
  defp stage_label(:retrieving), do: gettext("Searching the document...")
  defp stage_label(:assessing), do: gettext("Checking the sources...")
  defp stage_label(:generating), do: gettext("Writing the answer...")
  defp stage_label(_), do: gettext("Thinking...")

  attr :content, :string, default: nil

  defp markdown_content(assigns) do
    # Chat answers separate lines with single newlines; render them as hard breaks
    # so the layout is preserved instead of collapsing into run-on text.
    html = render_markdown(assigns.content || "", hardbreaks: true)
    assigns = assign(assigns, :html, html)
    # No wrapper element: the rendered blocks must be direct children of the
    # `.markdown` container so its edge-margin rules (`.markdown > :first-child`) match.
    ~H"{raw(@html)}"
  end
end
