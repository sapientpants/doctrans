// Mirrors the active theme onto the toggle's buttons as `aria-pressed`.
//
// Which option is selected is otherwise shown only by a CSS-positioned pill,
// which assistive technology cannot see, and the server cannot render the
// state because the choice lives in `localStorage` and is never sent to it.
//
// Shared by both bundles because both need it at different moments and neither
// can wait for the other: `theme.js` calls it before the first paint and on
// every change, while the `ThemeToggle` hook in `app.js` calls it again after a
// LiveView patch restores the server's placeholder attributes. esbuild copies
// these few lines into each output, which is cheaper than either bundle
// importing the other.

// "System" is the absence of `data-theme`, so it is what an unset attribute
// means. Kept in step with `SYSTEM` in `theme.js`.
const SYSTEM = "system"

// Document-wide rather than scoped to one toggle: the hook passes no root, and
// a page rendering two toggles should not leave the second one stale.
export const syncThemeToggles = () => {
  const current = document.documentElement.getAttribute("data-theme") || SYSTEM

  for (const button of document.querySelectorAll("[data-phx-theme]")) {
    button.setAttribute("aria-pressed", String(button.dataset.phxTheme === current))
  }
}
