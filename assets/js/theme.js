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
// So: a separate bundle, loaded render-blocking from `<head>`. Its only import
// is `theme_sync.js`, a handful of lines that esbuild copies into both outputs
// rather than a shared chunk, which is what keeps a second `--bundle` entry
// point cheap.

import {syncThemeToggles} from "./theme_sync"

// The key `phx:theme` and the `phx:set-theme` event name are Phoenix
// conventions, shared with `Layouts.theme_toggle/1`, which dispatches the
// event from `phx-click`.
const STORAGE_KEY = "phx:theme"

// "System" is the absence of a choice, not a third stored value: the attribute
// comes off `<html>` and the daisyUI themes resolve through
// `prefers-color-scheme` on their own. Storing the string instead would freeze
// the page at whatever the system preference was on the day it was chosen.
const SYSTEM = "system"

// The only values `data-theme` may take. `light` and `dark` are the two daisyUI
// themes declared in `app.css`.
const THEMES = [SYSTEM, "light", "dark"]

// Every value that reaches `setTheme` comes from outside this file -- storage
// written by an older build, another tab, a hand-dispatched event -- so each
// one is coerced to a theme that exists before it is applied. Anything else
// means "system", which is also the state that clears the stored key, so a
// stale value heals itself on the next load instead of being ignored forever.
const asTheme = (value) => (THEMES.includes(value) ? value : SYSTEM)

// Storage is not always writable -- Safari with cookies blocked, a browser set
// to deny site data -- and there it throws rather than returning null. An
// unhandled throw here would abort the rest of this file, which is where the
// event listeners are registered, so the toggle would go dead in exactly the
// way this file exists to prevent. Failing to persist costs the reader their
// choice on the next load; failing to listen costs them the control entirely.
const readTheme = () => {
  try {
    return localStorage.getItem(STORAGE_KEY)
  } catch {
    return null
  }
}

const writeTheme = (theme) => {
  try {
    if (theme === SYSTEM) {
      localStorage.removeItem(STORAGE_KEY)
    } else {
      localStorage.setItem(STORAGE_KEY, theme)
    }
  } catch {
    // The theme still applies for this page; it just will not outlive it.
  }
}

// Callers pass a value through `asTheme` first. The guard stays because this is
// the one place that writes the attribute, and `data-theme="undefined"` -- what
// an event from a node with no `data-phx-theme` used to produce -- is worse
// than it sounds: it matches no theme, it suppresses `prefers-color-scheme`
// because the attribute is present, and it leaves every button unpressed, so
// the page offers no clue about why it is stuck.
const setTheme = (theme) => {
  if (!THEMES.includes(theme)) {
    return
  }

  writeTheme(theme)

  if (theme === SYSTEM) {
    document.documentElement.removeAttribute("data-theme")
  } else {
    document.documentElement.setAttribute("data-theme", theme)
  }

  // A no-op during head parse, when the boot call below runs and no buttons
  // have been parsed yet -- `DOMContentLoaded` covers that first state. Every
  // later change comes through here.
  syncThemeToggles()
}

// Reload persistence. The guard matters for a server-rendered `data-theme`,
// which nothing sets today; leaving it in keeps this file from overwriting one
// if that changes.
if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(asTheme(readTheme()))
}

// The pressed state for the first paint. It is set here and not left to the
// `ThemeToggle` hook because the hook runs only once the LiveView socket has
// joined: until then -- and for good on a connection where it never does -- the
// buttons would still be announcing the server's "system" placeholder while the
// pill drew the real choice.
document.addEventListener("DOMContentLoaded", syncThemeToggles)

// Cross-tab updates. `storage` fires in every tab except the one that wrote,
// and a removed key arrives with a null `newValue` -- which is "system", the
// branch above that removes the key.
window.addEventListener("storage", (event) => {
  if (event.key === STORAGE_KEY) {
    setTheme(asTheme(event.newValue))
  }
})

// Theme selection. `JS.dispatch` fires the event on the clicked button, whose
// `data-phx-theme` names the choice. The optional chaining is for a dispatch
// on something that is not an element -- `window.dataset` is undefined, and
// reading through it throws.
window.addEventListener("phx:set-theme", (event) =>
  setTheme(asTheme(event.target?.dataset?.phxTheme))
)
