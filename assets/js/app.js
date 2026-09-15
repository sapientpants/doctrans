// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/doctrans"
import topbar from "../vendor/topbar"

// How long a transient flash notice stays on screen before it dismisses itself.
const DISMISS_AFTER_MS = 5000

// How close to the bottom of the chat transcript still counts as "reading the
// latest". Inside this band the message list follows streamed output; outside
// it, the reader's position is theirs to keep.
const CHAT_FOLLOW_THRESHOLD_PX = 64

// Custom hooks
const Hooks = {
  // Dismisses a transient flash on a timer by running the very `phx-click` the
  // server already rendered for a manual dismiss, so both paths animate the same
  // way and clear the same state. Notices that must outlive a timer (the
  // `phx-disconnected` connectivity banners, which are found by id when the
  // socket drops) render without this hook.
  AutoDismiss: {
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
  },
  // Follows streamed chat output, but only while the reader is already at the
  // bottom of the transcript.
  //
  // The hook this replaces slammed `scrollTop = scrollHeight` on every mutation
  // and every patch, so scrolling up to re-read an earlier answer was undone by
  // the very next streamed token -- while an answer was being written there was
  // no way to hold a reading position at all. `pinned` records whether the
  // reader is within CHAT_FOLLOW_THRESHOLD_PX of the bottom; only then does new
  // content scroll. Otherwise the `#chat-new-messages` affordance appears and
  // the scroll position is left exactly where the reader put it. Scrolling up
  // on its own never reveals the affordance: it announces content that arrived
  // unseen, not content already read.
  //
  // A MutationObserver is still what detects that content. `updated()` is not
  // enough: the finalized messages live in a `phx-update="stream"` container
  // that is a *child* of this element, so an append patches the child and never
  // calls `updated()` here, and a streamed delta only rewrites text inside
  // `#chat-streaming` -- hence `characterData` alongside `childList`/`subtree`.
  //
  // The affordance sits outside the scroll container in a `phx-update="ignore"`
  // wrapper. Its visibility is client state that no server assign knows about,
  // so without `ignore` the next unrelated patch would restore the rendered
  // `hidden` and drop the notice mid-answer.
  ChatScroll: {
    mounted() {
      this.newMessages = document.getElementById("chat-new-messages")
      this.jumpButton = document.getElementById("chat-jump-to-latest")

      this.pinned = true
      this.scrollToBottom()

      this.observer = new MutationObserver(() => this.contentArrived())
      this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })

      this.onScroll = () => this.readerScrolled()
      this.el.addEventListener("scroll", this.onScroll, { passive: true })

      // Asking a question is the reader's own move, so it should always take
      // them to their message. The listener sits on the document, as in
      // DialogFocus: LiveView repatches the form as the input disables and
      // re-enables, and a listener on a node that gets swapped out is lost.
      this.onSubmit = event => {
        if (event.target && event.target.id === "chat-form") {
          this.followLatest()
        }
      }
      document.addEventListener("submit", this.onSubmit, true)

      this.onJump = () => this.followLatest()
      if (this.jumpButton) {
        this.jumpButton.addEventListener("click", this.onJump)
      }
    },
    destroyed() {
      if (this.observer) {
        this.observer.disconnect()
      }
      this.el.removeEventListener("scroll", this.onScroll)
      document.removeEventListener("submit", this.onSubmit, true)
      if (this.jumpButton) {
        this.jumpButton.removeEventListener("click", this.onJump)
      }
    },
    contentArrived() {
      if (this.pinned) {
        this.scrollToBottom()
      } else {
        this.toggleAffordance(true)
      }
    },
    readerScrolled() {
      this.pinned = this.nearBottom()
      // Arriving back at the bottom is what dismisses the notice; there is
      // nothing left to announce once the latest message is on screen.
      if (this.pinned) {
        this.toggleAffordance(false)
      }
    },
    followLatest() {
      this.pinned = true
      this.toggleAffordance(false)
      this.scrollToBottom()
    },
    nearBottom() {
      const remaining = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      return remaining <= CHAT_FOLLOW_THRESHOLD_PX
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    },
    toggleAffordance(visible) {
      if (this.newMessages) {
        this.newMessages.classList.toggle("hidden", !visible)
      }
    }
  },
  // Keeps the chat input focused: on mount, and again whenever it re-enables
  // after a question finishes streaming (the input is disabled while loading,
  // which drops focus).
  ChatInput: {
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
      if (document.querySelector('[role="dialog"][aria-modal="true"]')) {
        return
      }
      if (!this.el.disabled) {
        this.el.focus()
      }
    }
  },
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
  DialogFocus: {
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
      const usable = active && active !== document.body && !this.el.contains(active)
      return usable ? active : null
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
    hasFocus() {
      const active = document.activeElement
      return !!active && active !== document.body && active !== document.documentElement
    },
    // Checked across several frames, not set once: the closing patch is still
    // settling, and a second patch carrying a status broadcast can disable the
    // trigger a frame after we focused it. Each frame reclaims focus only if it
    // is nowhere, so a user who has already tabbed on is left alone.
    restoreFocus(framesLeft) {
      if (!this.hasFocus()) {
        const target = this.returnElement()
        if (target) {
          target.focus()
        }
      }
      if (framesLeft > 0) {
        window.requestAnimationFrame(() => this.restoreFocus(framesLeft - 1))
      } else if (!this.hasFocus()) {
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
  },
  // Escape inside a `<select>` belongs to the select, not to the dialog around
  // it. macOS draws the popup at the OS level and never lets that Escape reach
  // the page; Chromium elsewhere bubbles it to the window, where the dialog's
  // `phx-window-keydown` would tear the dialog down and discard the files the
  // user had already chosen. Stopping it here makes every platform behave the
  // way macOS already does.
  EscapeStaysInSelect: {
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
  },
  // daisyUI opens this dropdown from CSS `:focus-within`, so "expanded" is just
  // whether focus is inside it. Nothing on the server knows that, so the
  // attribute is mirrored here rather than rendered.
  DropdownExpanded: {
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
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
