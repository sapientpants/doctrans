// Theme selection, as its own esbuild entry point rather than an inline
// `<head>` script.
//
// Two constraints meet here, and only this shape satisfies both.
//
// The router sends `script-src 'self'` on every browser response
// (`lib/doctrans_web/router.ex`). That directive blocks inline script: the
// `<script>` block this file replaces was not merely unconventional, it was
// refused by the browser, which is why theme selection did nothing. Restoring
// it with a nonce or a hash would re-admit inline script to the policy.
//
// And this is the one piece of the application's JavaScript that has to run
// before the first paint. `app.js` is `defer`red, so it executes only after
// the document is parsed. Until `data-theme` is set, the daisyUI themes
// resolve through `prefers-color-scheme` (`assets/css/app.css`), so the first
// paint follows the operating system -- and any reader whose stored choice
// disagrees with it, in either direction, would watch the page flip.
//
// So: a separate bundle, loaded render-blocking from `<head>`. It imports
// nothing, which is what keeps a second `--bundle` entry point cheap; a shared
// import would be copied into both outputs.

// The key `phx:theme` and the `phx:set-theme` event name are Phoenix
// conventions, shared with `Layouts.theme_toggle/1`, which dispatches the
// event from `phx-click`.
const STORAGE_KEY = "phx:theme"

// "System" is the absence of a choice, not a third stored value: the attribute
// comes off `<html>` and the daisyUI themes resolve through
// `prefers-color-scheme` on their own. Storing the string instead would freeze
// the page at whatever the system preference was on the day it was chosen.
const SYSTEM = "system"

const setTheme = (theme) => {
  if (theme === SYSTEM) {
    localStorage.removeItem(STORAGE_KEY)
    document.documentElement.removeAttribute("data-theme")
  } else {
    localStorage.setItem(STORAGE_KEY, theme)
    document.documentElement.setAttribute("data-theme", theme)
  }
}

// Reload persistence. The guard matters for a server-rendered `data-theme`,
// which nothing sets today; leaving it in keeps this file from overwriting one
// if that changes.
if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(localStorage.getItem(STORAGE_KEY) || SYSTEM)
}

// Cross-tab updates. `storage` fires in every tab except the one that wrote,
// and a removed key arrives with a null `newValue` -- which is "system", the
// branch above that removes the key.
window.addEventListener("storage", (event) => {
  if (event.key === STORAGE_KEY) {
    setTheme(event.newValue || SYSTEM)
  }
})

// Theme selection. `JS.dispatch` fires the event on the clicked button, whose
// `data-phx-theme` names the choice.
window.addEventListener("phx:set-theme", (event) => setTheme(event.target.dataset.phxTheme))
