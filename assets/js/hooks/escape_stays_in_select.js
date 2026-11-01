// Escape inside a `<select>` belongs to the select, not to the dialog around
// it. macOS draws the popup at the OS level and never lets that Escape reach
// the page; Chromium elsewhere bubbles it to the window, where the dialog's
// `phx-window-keydown` would tear the dialog down and discard the files the
// user had already chosen. Stopping it here makes every platform behave the
// way macOS already does.
export const EscapeStaysInSelect = {
  mounted() {
    this.onKeyDown = event => {
      if (event.key === "Escape") {
        event.stopPropagation()
      }
    }
    this.el.addEventListener("keydown", this.onKeyDown)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown)
  }
}
