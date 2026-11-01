import {dialogOpen} from "./focus"

// Keeps the chat input focused: on mount, and again whenever it re-enables
// after a question finishes streaming (the input is disabled while loading,
// which drops focus).
export const ChatInput = {
  mounted() {
    this.focusIfEnabled()
  },
  updated() {
    this.focusIfEnabled()
  },
  focusIfEnabled() {
    // Never pull focus out of an open dialog. The chat panel and the reprocess
    // dialog coexist on the Show page, and this input re-enables every time an
    // answer finishes streaming -- which would drag focus to the page behind
    // the dialog while a screen reader is still reading it.
    if (dialogOpen()) {
      return
    }
    if (!this.el.disabled) {
      this.el.focus()
    }
  }
}
