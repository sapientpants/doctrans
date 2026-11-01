// daisyUI opens this dropdown from CSS `:focus-within`, so "expanded" is just
// whether focus is inside it. Nothing on the server knows that, so the
// attribute is mirrored here rather than rendered.
export const DropdownExpanded = {
  mounted() {
    this.root = this.el.closest(".dropdown")
    if (!this.root) {
      return
    }
    // On focusout the focus has not moved yet, so `activeElement` is still the
    // element being left; `relatedTarget` is where it is going.
    this.sync = event => {
      const next = event.type === "focusout" ? event.relatedTarget : document.activeElement
      const inside = !!next && this.root.contains(next)
      this.el.setAttribute("aria-expanded", String(inside))
    }
    this.root.addEventListener("focusin", this.sync)
    this.root.addEventListener("focusout", this.sync)
  },
  destroyed() {
    if (!this.root) {
      return
    }
    this.root.removeEventListener("focusin", this.sync)
    this.root.removeEventListener("focusout", this.sync)
  }
}
