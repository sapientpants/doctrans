// How close to the bottom of the chat transcript still counts as "reading the
// latest". Inside this band the message list follows streamed output; outside
// it, the reader's position is theirs to keep.
const CHAT_FOLLOW_THRESHOLD_PX = 64

// Follows streamed chat output, but only while the reader is already at the
// bottom of the transcript. Scrolling up holds that position and reveals the
// "new messages" affordance instead; returning to the bottom, clicking it, or
// asking a question re-pins. Scrolling up alone never reveals the affordance:
// it announces content that arrived unseen, not content already read.
//
// `updated()` cannot replace the MutationObserver. The finalized messages live
// in a `phx-update="stream"` container that is a *child* of this element, so
// an append patches the child without calling `updated()` here, and a streamed
// delta only rewrites text inside the streaming answer -- hence `characterData`
// alongside `childList`/`subtree`.
//
// Neither observer sees a *resize*, and a container that gets shorter fires no
// scroll event either, because `scrollTop` stays legal when the maximum offset
// grows. Browser zoom, a window resize, crossing the `lg` breakpoint where the
// panel flips from viewport height to column height, and the soft keyboard all
// land there, so a ResizeObserver re-pins as well.
//
// Every element this reaches for is named by a `data-` attribute rather than a
// hardcoded id, and a miss is reported: each of these failures is otherwise
// silent, leaving an affordance that never appears or a button that never
// binds.
export const ChatScroll = {
  mounted() {
    this.newMessages = this.resolve("data-new-messages")
    this.jumpButton = this.resolve("data-jump-to-latest")
    this.liveRegion = this.resolve("data-live-region")
    this.submitSelector = this.el.getAttribute("data-follow-on-submit")

    this.pinned = true
    this.scrollToBottom()

    this.observer = new MutationObserver(() => this.contentArrived())
    this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })

    this.resizeObserver = new ResizeObserver(() => this.containerResized())
    this.resizeObserver.observe(this.el)

    this.onScroll = () => this.readerScrolled()
    this.el.addEventListener("scroll", this.onScroll, { passive: true })

    // Asking a question is the reader's own move, so it should always take
    // them to their message. The listener sits on the document, as in
    // DialogFocus: LiveView repatches the form as the input disables and
    // re-enables, and a listener on a node that gets swapped out is lost.
    this.onSubmit = event => {
      const target = event.target
      if (this.submitSelector && target instanceof Element && target.matches(this.submitSelector)) {
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
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    this.el.removeEventListener("scroll", this.onScroll)
    document.removeEventListener("submit", this.onSubmit, true)
    if (this.jumpButton) {
      this.jumpButton.removeEventListener("click", this.onJump)
    }
  },
  contentArrived() {
    // `pinned` is refreshed from the `scroll` event, which the browser only
    // dispatches on the next rendering frame, while this callback is a
    // microtask running at the end of every task -- and each streamed delta
    // arrives as its own WebSocket message task. A delta landing between the
    // reader's gesture and that frame would otherwise still see the stale
    // `true` and yank them back down, which is the exact thing this hook
    // exists to prevent. Appending content leaves `scrollTop` untouched while
    // `scrollHeight` grows, so an offset below the one we last set ourselves
    // is always the reader's own move.
    if (this.pinned && this.autoTop !== undefined && this.el.scrollTop < this.autoTop - 1) {
      this.pinned = false
    }

    if (this.pinned) {
      this.scrollToBottom()
    } else if (this.nearBottom()) {
      // Content shrinks as well as grows: interrupting an answer drops the
      // streaming block. With nothing left below the fold there is nothing to
      // announce, and a shrink to shorter than the container fires no scroll
      // event that would clear the notice later.
      this.toggleAffordance(false)
    } else {
      this.toggleAffordance(true)
    }
  },
  containerResized() {
    if (this.pinned) {
      this.scrollToBottom()
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
    // Remembered so `contentArrived` can tell our own scrolling apart from
    // the reader's.
    this.autoTop = this.el.scrollTop
  },
  toggleAffordance(visible) {
    if (this.newMessages) {
      this.newMessages.classList.toggle("hidden", !visible)
    }

    // The button is announced by changing the *text* of a region that stays
    // rendered, not by unhiding one: toggling `display` on an `aria-live`
    // element is not reliably announced across screen readers. Writing the
    // same text twice can re-announce, so an unchanged value is left alone.
    if (this.liveRegion) {
      const announcement = visible ? this.liveRegion.getAttribute("data-announce") || "" : ""
      if (this.liveRegion.textContent !== announcement) {
        this.liveRegion.textContent = announcement
      }
    }
  },
  resolve(attribute) {
    const id = this.el.getAttribute(attribute)
    const el = id && document.getElementById(id)
    if (!el) {
      console.error(`ChatScroll: ${attribute}="${id}" matched no element`)
    }
    return el
  }
}
