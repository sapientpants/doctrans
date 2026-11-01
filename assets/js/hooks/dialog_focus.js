import {hasFocus} from "./focus"

// Owns focus for an open dialog: where it starts, where Tab may go, and where
// it returns to on close.
//
// `JS.push_focus/0` cannot do the last part. It pushes the element the command
// is attached to -- the dialog -- not the element that was focused before it
// opened, so popping focuses a node that is being removed and focus lands on
// the body. The trigger is named by `data-return-focus` instead, which also
// survives a browser that does not focus a button on click.
//
// The focusable set is read again on every keypress rather than cached at
// mount: LiveView owns this markup and repatches it while the dialog is open,
// as upload entries come and go. The listener sits on the document because
// focus can still be outside the dialog when a key lands, and a keydown out
// there would never reach the dialog element.
export const DialogFocus = {
  mounted() {
    this.returnTo = this.returnTarget()
    this.onKeyDown = event => this.trapTab(event)
    document.addEventListener("keydown", this.onKeyDown, true)
    this.focusFirst()
  },
  destroyed() {
    document.removeEventListener("keydown", this.onKeyDown, true)
    this.restoreFocus(3)
  },
  returnTarget() {
    const selector = this.el.getAttribute("data-return-focus")
    const named = selector && document.querySelector(selector)
    if (named) {
      return named
    }
    const active = document.activeElement
    return hasFocus() && !this.el.contains(active) ? active : null
  },
  // The trigger, re-resolved rather than reused from mount, and only if it can
  // actually take focus. The patch that closes a dialog is often the same one
  // that rewrites its trigger: confirming a page reprocess resets the page to
  // `pending`, which drops `#show-reprocess` from the DOM entirely, and
  // confirming a document reprocess sets the status to `queued`, which
  // disables `#show-document-reprocess` a patch later. `focus()` on a removed
  // or disabled element silently does nothing.
  returnElement() {
    const usable = el =>
      el && el.isConnected && !el.disabled && el.getClientRects().length > 0
    const selector = this.el.getAttribute("data-return-focus")
    const named = selector && document.querySelector(selector)
    if (usable(named)) {
      return named
    }
    return usable(this.returnTo) ? this.returnTo : null
  },
  // A dialog that cannot hand focus back to its trigger must still hand it
  // somewhere. Leaving it on `<body>` restarts a keyboard user at the top of
  // the page and strands a screen-reader user with no context (WCAG 2.4.3).
  focusFallback() {
    const selector = this.el.getAttribute("data-return-fallback") || "main"
    const anchor = document.querySelector(selector)
    if (!anchor) {
      return
    }
    if (anchor.tabIndex < 0) {
      anchor.setAttribute("tabindex", "-1")
    }
    anchor.focus()
  },
  // Checked across several frames, not set once: the closing patch is still
  // settling, and a second patch carrying a status broadcast can disable the
  // trigger a frame after we focused it. Each frame reclaims focus only if it
  // is nowhere, so a user who has already tabbed on is left alone.
  restoreFocus(framesLeft) {
    if (!hasFocus()) {
      const target = this.returnElement()
      if (target) {
        target.focus()
      }
    }
    if (framesLeft > 0) {
      window.requestAnimationFrame(() => this.restoreFocus(framesLeft - 1))
    } else if (!hasFocus()) {
      this.focusFallback()
    }
  },
  focusFirst() {
    // daisyUI opens the upload dialog through a `visibility` transition marked
    // `allow-discrete`: it computes as `hidden` when the hook mounts and for
    // the whole first frame, turning `visible` only on the second. A node in a
    // hidden subtree cannot take focus, so the first attempt is expected to
    // fail and the retries are what actually land it.
    //
    // Three frames covers the one transition this app has; it is not a general
    // guarantee. Each attempt is guarded: once focus is inside, the later ones
    // must not yank it back to the top.
    const attempt = () => {
      if (this.el.contains(document.activeElement)) {
        return
      }
      const focusable = this.focusableElements()
      if (focusable.length > 0) {
        focusable[0].focus()
      }
    }
    attempt()
    window.requestAnimationFrame(() => {
      attempt()
      window.requestAnimationFrame(attempt)
    })
  },
  trapTab(event) {
    if (event.key !== "Tab") {
      return
    }

    // With the socket down, every way out of this dialog -- Escape, Cancel,
    // the close button -- is a server round-trip that cannot complete, and
    // LiveView does not call `destroyed()` on disconnect. Holding Tab inside
    // would leave no way out at all (WCAG 2.1.2), so the trap yields.
    if (window.liveSocket && !window.liveSocket.isConnected()) {
      return
    }

    const focusable = this.focusableElements()
    if (focusable.length === 0) {
      return
    }

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const active = document.activeElement

    if (!this.el.contains(active)) {
      event.preventDefault()
      if (event.shiftKey) {
        last.focus()
      } else {
        first.focus()
      }
    } else if (event.shiftKey && active === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && active === last) {
      event.preventDefault()
      first.focus()
    }
  },
  focusableElements() {
    const selector = [
      "a[href]",
      "button:not([disabled])",
      "input:not([disabled])",
      "select:not([disabled])",
      "textarea:not([disabled])",
      "[tabindex]"
    ].join(", ")

    // `tabIndex >= 0` is the load-bearing filter, not the selector: a dialog's
    // backdrop is a `<button tabindex="-1">`, which `button:not([disabled])`
    // matches. Counting it made it the trap's "last" element, so the real last
    // control was never recognised and Tab walked straight out of the dialog.
    //
    // getClientRects() rather than offsetParent: the file input is `sr-only`
    // (clipped to 1px) yet must stay reachable, while `display: none`
    // elements have no rects and drop out.
    return Array.from(this.el.querySelectorAll(selector)).filter(
      el => el.tabIndex >= 0 && el.getClientRects().length > 0
    )
  }
}
