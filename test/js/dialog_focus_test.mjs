import assert from "node:assert/strict"
import test from "node:test"
import vm from "node:vm"

import {fakeBrowser} from "./fake_dom.mjs"
import {moduleLoader, mountHook} from "./harness.mjs"

// A dialog as `core_components.ex` renders one, opened from a trigger on the
// page: close button, the controls of the reprocess form -- one of them an
// `sr-only` file input, clipped but rendered -- Cancel, and last of all the
// backdrop, a `<button tabindex="-1">`. One hidden control stands for anything
// `display: none` keeps out of the tab order.
async function openDialog({focusBefore = "trigger", hidden = false} = {}) {
  const browser = fakeBrowser()
  const {el, document} = browser

  const main = el({tag: "main"})
  const trigger = el({tag: "button", id: "show-reprocess"})
  const elsewhere = el({tag: "button", id: "elsewhere"})
  const dialog = el({id: "reprocess-modal", attributes: {role: "dialog", "data-return-focus": "#show-reprocess"}})
  const close = el({tag: "button", id: "reprocess-modal-close", visible: !hidden})
  const srOnlyInput = el({tag: "input", id: "file-input", attributes: {class: "sr-only"}, visible: !hidden})
  const select = el({tag: "select", id: "model-select", visible: !hidden})
  const collapsed = el({tag: "button", id: "collapsed", visible: false})
  const cancel = el({tag: "button", id: "reprocess-cancel", visible: !hidden})
  const backdrop = el({tag: "button", id: "backdrop", attributes: {tabindex: "-1"}, visible: !hidden})
  dialog.append(close, srOnlyInput, select, collapsed, cancel, backdrop)
  document.body.append(main, trigger, elsewhere, dialog)

  if (focusBefore === "trigger") trigger.focus()
  if (focusBefore === "elsewhere") elsewhere.focus()

  const importModule = moduleLoader(vm.createContext(browser.context))
  const {DialogFocus} = await importModule("./hooks/dialog_focus")
  const hook = mountHook(DialogFocus, dialog)

  const tab = ({shiftKey = false} = {}) => document.dispatch("keydown", {key: "Tab", shiftKey})

  return {...browser, hook, main, trigger, elsewhere, dialog, close, srOnlyInput, select, cancel, backdrop, tab}
}

test("the first control takes focus on mount", async () => {
  const page = await openDialog()
  assert.equal(page.document.activeElement, page.close)
})

test("a dialog still hidden by its opening transition is focused on a later frame", async () => {
  const page = await openDialog({hidden: true})
  assert.equal(page.document.activeElement, page.trigger)

  for (const control of [page.close, page.srOnlyInput, page.select, page.cancel, page.backdrop]) control.visible = true
  page.nextFrame()
  assert.equal(page.document.activeElement, page.close)

  // The retry that follows must not pull focus back once it is inside.
  page.select.focus()
  page.nextFrame()
  assert.equal(page.document.activeElement, page.select)
})

test("the tab order keeps the sr-only input, drops the backdrop and the hidden control", async () => {
  const page = await openDialog()
  // `Array.from` rebuilds the list in this realm: the hook's array was made in
  // the vm context, whose `Array.prototype` is a different object.
  assert.deepEqual(
    Array.from(page.hook.focusableElements(), el => el.id),
    ["reprocess-modal-close", "file-input", "model-select", "reprocess-cancel"]
  )
})

test("Tab wraps from the last control to the first, and Shift+Tab back", async () => {
  // Counting the backdrop made *it* the last element, so Tab from Cancel was
  // never recognised as leaving and walked straight out of the dialog.
  const page = await openDialog()
  page.cancel.focus()
  const forward = page.tab()
  assert.equal(forward.defaultPrevented, true)
  assert.equal(page.document.activeElement, page.close)

  const backward = page.tab({shiftKey: true})
  assert.equal(backward.defaultPrevented, true)
  assert.equal(page.document.activeElement, page.cancel)

  // In the middle of the ring, the browser moves focus itself.
  page.srOnlyInput.focus()
  assert.equal(page.tab().defaultPrevented, false)
  assert.equal(page.document.activeElement, page.srOnlyInput)
})

test("Tab from outside the dialog is pulled inside", async () => {
  const page = await openDialog()
  page.elsewhere.focus()
  page.tab()
  assert.equal(page.document.activeElement, page.close)

  page.elsewhere.focus()
  page.tab({shiftKey: true})
  assert.equal(page.document.activeElement, page.cancel)
})

test("the trap yields while the socket is down", async () => {
  // Every way out of the dialog is a server round-trip then; holding Tab
  // inside would leave no way out at all.
  const page = await openDialog()
  page.window.liveSocket = {isConnected: () => false}
  page.cancel.focus()
  assert.equal(page.tab().defaultPrevented, false)
  assert.equal(page.document.activeElement, page.cancel)
})

test("closing hands focus back to the trigger", async () => {
  const page = await openDialog()
  page.dialog.remove()
  assert.equal(page.document.activeElement, page.document.body)

  page.hook.destroyed()
  assert.equal(page.document.activeElement, page.trigger)

  // The later frames reclaim focus only if it is nowhere: a reader who tabbed
  // on in the meantime is left alone.
  page.elsewhere.focus()
  for (let frame = 0; frame < 3; frame++) page.nextFrame()
  assert.equal(page.document.activeElement, page.elsewhere)
  assert.equal(page.trigger.focusCount, 2)
})

test("a trigger disabled a frame after close hands focus to where the dialog opened from", async () => {
  // The closing patch is still settling: a status broadcast can disable the
  // trigger after the first frame focused it, which drops focus to the body.
  const page = await openDialog({focusBefore: "elsewhere"})
  page.dialog.remove()
  page.hook.destroyed()
  assert.equal(page.document.activeElement, page.trigger)

  page.trigger.disabled = true
  assert.equal(page.document.activeElement, page.document.body)

  page.nextFrame()
  assert.equal(page.document.activeElement, page.elsewhere)
})

test("with nothing to return to, focus lands on the main landmark rather than the body", async () => {
  const page = await openDialog({focusBefore: "body"})
  page.trigger.remove()
  page.dialog.remove()
  page.hook.destroyed()

  for (let frame = 0; frame < 3; frame++) {
    assert.equal(page.document.activeElement, page.document.body)
    page.nextFrame()
  }

  assert.equal(page.main.getAttribute("tabindex"), "-1")
  assert.equal(page.document.activeElement, page.main)
})
