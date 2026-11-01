// How long a transient flash notice stays on screen before it dismisses itself.
const DISMISS_AFTER_MS = 5000

// Dismisses a transient flash on a timer by running the very `phx-click` the
// server already rendered for a manual dismiss, so both paths animate the same
// way and clear the same state. Notices that must outlive a timer (the
// `phx-disconnected` connectivity banners, which are found by id when the
// socket drops) render without this hook.
export const AutoDismiss = {
  mounted() {
    this.message = this.el.textContent
    this.scheduleDismiss()
  },
  updated() {
    // Restart the countdown only when the notice actually says something new.
    // Keying off the patch itself would let a frequently-rendering LiveView
    // hold a flash on screen indefinitely.
    if (this.el.textContent === this.message) {
      return
    }

    this.message = this.el.textContent
    // A dismissal already under way left `display: none` on this node, and a
    // patch carrying a replacement message reuses it. Undo that, or the new
    // message is patched into a hidden node and never seen.
    this.el.style.display = ""
    this.scheduleDismiss()
  },
  destroyed() {
    clearTimeout(this.dismissTimer)
  },
  scheduleDismiss() {
    clearTimeout(this.dismissTimer)
    this.dismissTimer = setTimeout(() => {
      this.js().exec(this.el.getAttribute("phx-click"))
    }, DISMISS_AFTER_MS)
  }
}
