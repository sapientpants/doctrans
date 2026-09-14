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

// Custom hooks
const Hooks = {
  AutoDismiss: {
    mounted() {
      setTimeout(() => {
        this.el.style.transition = "opacity 300ms ease-out"
        this.el.style.opacity = "0"
        setTimeout(() => {
          this.el.remove()
        }, 300)
      }, 5000)
    }
  },
  ScrollToBottom: {
    mounted() {
      this.scrollToBottom()
      this.observer = new MutationObserver(() => this.scrollToBottom())
      this.observer.observe(this.el, { childList: true, subtree: true })
    },
    updated() {
      this.scrollToBottom()
    },
    destroyed() {
      if (this.observer) {
        this.observer.disconnect()
      }
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
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
      const target = this.returnTo
      if (target && target.isConnected) {
        // The patch that removed the dialog is still settling, so claim focus
        // again once it has.
        target.focus()
        window.requestAnimationFrame(() => target.focus())
      }
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
    focusFirst() {
      // daisyUI opens the upload dialog through a `visibility` transition marked
      // `allow-discrete`: it computes as `hidden` when the hook mounts and for
      // the whole first frame, turning `visible` only on the second. A node in a
      // hidden subtree cannot take focus, and it keeps its client rects
      // throughout, so there is nothing to test for -- only to wait for. Hence
      // the nested frames, the same way LiveView defers its own focus commands.
      //
      // Each attempt is guarded: once focus is inside, the later ones must not
      // yank it back to the top.
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

      const focusable = this.focusableElements()
      if (focusable.length === 0) {
        return
      }

      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      const active = document.activeElement

      if (!this.el.contains(active)) {
        event.preventDefault()
        first.focus()
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
