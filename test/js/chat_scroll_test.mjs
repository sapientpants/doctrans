import assert from "node:assert/strict"
import test from "node:test"
import vm from "node:vm"

import {fakeBrowser} from "./fake_dom.mjs"
import {moduleLoader, mountHook} from "./harness.mjs"

// The chat transcript as `chat_components.ex` renders it: the scroller the
// hook mounts on, named by the same data attributes, with the affordance, the
// live region and the form it has to find.
async function transcript({attributes = true} = {}) {
  const browser = fakeBrowser()
  const {el, document} = browser

  const scroller = el({
    id: "chat-scroll",
    scrollHeight: 1000,
    clientHeight: 300,
    attributes: attributes
      ? {
          "data-new-messages": "chat-new-messages",
          "data-jump-to-latest": "chat-jump-to-latest",
          "data-live-region": "chat-new-messages-announcement",
          "data-follow-on-submit": "#chat-form",
        }
      : {},
  })
  const newMessages = el({id: "chat-new-messages"})
  newMessages.classList.toggle("hidden", true)
  const jumpButton = el({tag: "button", id: "chat-jump-to-latest"})
  newMessages.append(jumpButton)
  const liveRegion = el({id: "chat-new-messages-announcement", attributes: {"data-announce": "New messages"}})
  const form = el({tag: "form", id: "chat-form"})
  document.body.append(scroller, newMessages, liveRegion, form)

  const importModule = moduleLoader(vm.createContext(browser.context))
  const {ChatScroll} = await importModule("./hooks/chat_scroll")
  const hook = mountHook(ChatScroll, scroller)

  return {
    ...browser,
    hook,
    scroller,
    newMessages,
    liveRegion,
    form,
    // What the browser does after LiveView patches the transcript.
    contentArrived: () => browser.mutationObservers[0].trigger(),
    containerResized: () => browser.resizeObservers[0].trigger(),
    noticeVisible: () => !newMessages.classList.contains("hidden"),
  }
}

test("mounting pins the transcript to its bottom", async () => {
  const page = await transcript()
  assert.equal(page.scroller.scrollTop, 700)
  assert.equal(page.hook.pinned, true)
  assert.equal(page.noticeVisible(), false)
  assert.deepEqual(page.errors, [])
})

test("a delta landing before the scroll event still sees the reader's move", async () => {
  // The race the guard exists for: the reader has scrolled up, but the
  // `scroll` event that would refresh `pinned` has not fired yet when the next
  // streamed delta mutates the transcript.
  const page = await transcript()
  page.scroller.scrollTop = 200
  page.scroller.scrollHeight = 1200
  page.contentArrived()

  assert.equal(page.hook.pinned, false)
  assert.equal(page.scroller.scrollTop, 200, "the reader was yanked back to the bottom")
  assert.equal(page.noticeVisible(), true)
  assert.equal(page.liveRegion.textContent, "New messages")
})

test("content that shrinks under an unpinned reader clears the notice", async () => {
  const page = await transcript()
  page.scroller.scrollTop = 200
  page.scroller.dispatch("scroll")
  assert.equal(page.hook.pinned, false)

  page.scroller.scrollHeight = 1200
  page.contentArrived()
  assert.equal(page.noticeVisible(), true)

  // Interrupting an answer drops the streaming block. There is nothing below
  // the fold to announce any more, and no scroll event is coming to say so.
  page.scroller.scrollHeight = 450
  page.contentArrived()

  assert.equal(page.noticeVisible(), false)
  assert.equal(page.liveRegion.textContent, "")
  assert.equal(page.hook.pinned, false, "a shrink is not the reader returning")
})

test("a resize re-pins only while the reader is pinned", async () => {
  const page = await transcript()
  page.scroller.clientHeight = 200
  page.containerResized()
  assert.equal(page.scroller.scrollTop, 800)

  page.scroller.scrollTop = 100
  page.scroller.dispatch("scroll")
  page.scroller.clientHeight = 150
  page.containerResized()
  assert.equal(page.scroller.scrollTop, 100)
})

test("the live region is written only when its text changes", async () => {
  // Writing the same announcement twice can re-announce it, so a second
  // mutation while the notice already shows must leave the node alone.
  const page = await transcript()
  page.scroller.scrollTop = 0
  page.scroller.dispatch("scroll")
  page.scroller.scrollHeight = 1200
  page.contentArrived()
  assert.equal(page.liveRegion.textContent, "New messages")

  page.liveRegion.textContent = "New messages"
  const before = page.liveRegion
  page.scroller.scrollHeight = 1400
  page.contentArrived()
  assert.equal(before.textContent, "New messages")
})

test("submitting the form, clicking the button and returning to the bottom all re-pin", async () => {
  const page = await transcript()
  const unpin = () => {
    page.scroller.scrollTop = 0
    page.scroller.dispatch("scroll")
    page.scroller.scrollHeight += 100
    page.contentArrived()
    assert.equal(page.noticeVisible(), true)
  }

  unpin()
  page.document.dispatch("submit", {target: page.form})
  assert.equal(page.hook.pinned, true)
  assert.equal(page.scroller.scrollTop, page.scroller.maxScrollTop())
  assert.equal(page.noticeVisible(), false)

  unpin()
  page.newMessages.children[0].dispatch("click")
  assert.equal(page.hook.pinned, true)
  assert.equal(page.noticeVisible(), false)

  unpin()
  page.scroller.scrollTop = page.scroller.maxScrollTop()
  page.scroller.dispatch("scroll")
  assert.equal(page.hook.pinned, true)
  assert.equal(page.noticeVisible(), false)

  // A submit from some other form is not the reader asking a question.
  unpin()
  page.document.dispatch("submit", {target: page.el({tag: "form", id: "other-form"})})
  assert.equal(page.hook.pinned, false)
})

test("markup that names no targets is reported once per miss, and the hook still unmounts", async () => {
  const page = await transcript({attributes: false})
  assert.equal(page.errors.length, 4)
  assert.ok(page.errors.every(message => message.startsWith("ChatScroll:")))

  page.hook.destroyed()
  assert.equal(page.scroller.listenerCount("scroll"), 0)
  assert.equal(page.document.listenerCount("submit"), 0)
  assert.deepEqual(page.mutationObservers[0].targets, [])
  assert.deepEqual(page.resizeObservers[0].targets, [])
})
