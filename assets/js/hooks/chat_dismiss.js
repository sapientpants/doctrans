import {dialogOpen, hasFocus} from "./focus"

// Escape-to-close and focus-return for the chat overlay -- the two things a
// modal dialog would provide for free. The panel deliberately is not one
// (`ChatInput` declines to focus inside an `aria-modal` element, which would
// stop the input being refocused after every answer), so they are added here.
//
// Only while it actually is an overlay: from `lg:` up the panel is an in-flow
// sidebar, where Escape closing a docked column would be a surprise.
export const ChatDismiss = {
  mounted() {
    this.onKeyDown = event => {
      if (event.key !== "Escape" || !this.isOverlay()) {
        return
      }
      // An open dialog owns Escape. Without this, dismissing the reprocess
      // dialog would also close the chat behind it.
      if (dialogOpen()) {
        return
      }
      event.preventDefault()
      this.pushEvent("toggle_chat", {})
    }
    document.addEventListener("keydown", this.onKeyDown, true)
  },
  destroyed() {
    document.removeEventListener("keydown", this.onKeyDown, true)
    this.restoreFocus()
  },
  isOverlay() {
    const query = this.el.getAttribute("data-overlay-media")
    return !query || window.matchMedia(query).matches
  },
  // Only when the closing panel took focus down with it. A reader who has
  // already clicked or tabbed elsewhere is left where they are.
  restoreFocus() {
    if (hasFocus()) {
      return
    }
    const selector = this.el.getAttribute("data-return-focus")
    const target = selector && document.querySelector(selector)
    if (target && target.isConnected && !target.disabled) {
      target.focus()
    }
  }
}
