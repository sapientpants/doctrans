// Focus checks shared by the hooks that move focus around.
//
// Both used to be written out inline in more than one hook, and the two copies
// of each had already begun to drift in wording. One definition keeps "focus is
// nowhere" and "a dialog is open" meaning the same thing everywhere.

// True when something on the page actually holds focus. `activeElement` is
// `<body>` -- or, in some browsers, `<html>` -- after a focused node is removed
// or disabled, which is what "nowhere" means here.
export const hasFocus = () => {
  const active = document.activeElement
  return !!active && active !== document.body && active !== document.documentElement
}

// True while a modal dialog is open. An open dialog owns Escape and focus: the
// chat panel must neither close on an Escape meant for the dialog nor pull
// focus out from under it.
export const dialogOpen = () =>
  !!document.querySelector('[role="dialog"][aria-modal="true"]')
