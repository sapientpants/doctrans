import {syncThemeToggles} from "../theme_sync"

// Restores the toggle's `aria-pressed` state after LiveView touches it.
//
// `theme.js` owns the state itself: it applies `data-theme` and mirrors it
// onto the buttons before the first paint, and again on every click and
// every cross-tab `storage` event, none of which need a socket. What it
// cannot see is a server patch, which re-renders the group from a template
// that does not know the theme and so restores the "system" placeholder.
// That is what these two callbacks undo -- `mounted` for the patch that
// lands when the socket joins, `updated` for every one after.
//
// Deliberately without `phx-update="ignore"`, despite writing into
// server-rendered DOM: ignoring the subtree would also freeze the gettext'd
// `aria-label`s, so the group would keep the locale it first rendered in.
// Re-syncing after the patch is the cheaper trade.
export const ThemeToggle = {
  mounted() {
    syncThemeToggles()
  },
  updated() {
    syncThemeToggles()
  }
}
