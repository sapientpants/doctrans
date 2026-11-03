// The slice of the DOM the hooks under test reach for, and nothing more.
//
// `node:vm` gives the modules no browser, and the hooks need one that can hold
// focus, report scroll geometry, match a handful of selectors and fire the
// observers a browser fires on its own. Each of those is modelled here exactly
// as far as the hooks use it: `focus()` refuses what a browser refuses -- a
// disconnected, disabled or unrendered node -- `scrollTop` clamps the way a
// real scroller does, and an observer or animation frame runs only when a test
// says so, which is what makes the race the ChatScroll hook guards against
// reproducible at all.
import assert from "node:assert/strict"

const FOCUSABLE_TAGS = new Set(["button", "input", "select", "textarea"])

// Dispatch for `addEventListener`/`removeEventListener`. The capture flag is
// accepted and ignored: there is no propagation here to capture ahead of.
const eventTarget = () => {
  const handlers = new Map()
  return {
    addEventListener(name, callback) {
      handlers.set(name, [...(handlers.get(name) || []), callback])
    },
    removeEventListener(name, callback) {
      handlers.set(name, (handlers.get(name) || []).filter(handler => handler !== callback))
    },
    listenerCount(name) {
      return (handlers.get(name) || []).length
    },
    dispatch(name, event = {}) {
      if (!("defaultPrevented" in event)) {
        event.defaultPrevented = false
        event.preventDefault = () => { event.defaultPrevented = true }
      }
      for (const callback of handlers.get(name) || []) callback(event)
      return event
    },
  }
}

// One simple selector: `tag`, `#id`, `[attr]`, `[attr="value"]`, `:not([attr])`,
// in any combination, which covers every selector the hooks write or are
// handed from the markup.
const matchesSimple = (el, selector) => {
  let rest = selector.trim()
  const tag = rest.match(/^[a-z]+/)
  if (tag) {
    if (el.tagName !== tag[0]) return false
    rest = rest.slice(tag[0].length)
  }
  const parts = rest.match(/#[\w-]+|:not\(\[[^\]]+\]\)|\[[^\]]+\]/g) || []
  assert.equal(parts.join(""), rest, `unsupported selector: ${selector}`)
  for (const part of parts) {
    if (part.startsWith("#")) {
      if (el.id !== part.slice(1)) return false
    } else if (part.startsWith(":not(")) {
      if (hasAttribute(el, part.slice(5, -1))) return false
    } else if (!hasAttribute(el, part)) {
      return false
    }
  }
  return true
}

const hasAttribute = (el, bracket) => {
  const match = bracket.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/)
  assert.ok(match, `unsupported attribute selector: ${bracket}`)
  const value = el.getAttribute(match[1])
  return value !== null && (match[2] === undefined || value === match[2])
}

export class FakeElement {
  #document
  #attributes = new Map()
  #scrollTop = 0

  constructor(document, {tag = "div", id = null, attributes = {}, visible = true, scrollHeight = 0, clientHeight = 0} = {}) {
    this.#document = document
    this.tagName = tag
    this.children = []
    this.parentNode = null
    this.isConnected = false
    this.visible = visible
    this.textContent = ""
    this.scrollHeight = scrollHeight
    this.clientHeight = clientHeight
    this.focusCount = 0
    Object.assign(this, eventTarget())
    const classes = new Set()
    this.classList = {
      toggle: (name, force) => {
        if (force === undefined ? !classes.has(name) : force) classes.add(name)
        else classes.delete(name)
      },
      contains: name => classes.has(name),
    }
    if (id) this.setAttribute("id", id)
    for (const [name, value] of Object.entries(attributes)) this.setAttribute(name, value)
  }

  get id() { return this.getAttribute("id") || "" }
  getAttribute(name) { return this.#attributes.get(name) ?? null }
  hasAttribute(name) { return this.#attributes.has(name) }
  setAttribute(name, value) { this.#attributes.set(name, String(value)) }
  removeAttribute(name) { this.#attributes.delete(name) }

  // Disabling the focused control drops focus to the body, as browsers do.
  get disabled() { return this.hasAttribute("disabled") }
  set disabled(value) {
    if (value) {
      this.setAttribute("disabled", "")
      this.#document.blurIfActive(this)
    } else {
      this.removeAttribute("disabled")
    }
  }

  // Native focusability unless `tabindex` says otherwise: the hooks read the
  // property, the markup sets the attribute.
  get tabIndex() {
    if (this.hasAttribute("tabindex")) return parseInt(this.getAttribute("tabindex"), 10)
    if (FOCUSABLE_TAGS.has(this.tagName) || (this.tagName === "a" && this.hasAttribute("href"))) return 0
    return -1
  }
  set tabIndex(value) { this.setAttribute("tabindex", value) }

  // `display: none` leaves an element with no boxes; clipping to 1px does not.
  getClientRects() { return this.visible ? [{width: 1, height: 1}] : [] }

  // A scroller never scrolls past its content, and content that shrinks pulls
  // the offset back with it -- the geometry behind ChatScroll's shrink branch.
  get scrollTop() { return Math.min(this.#scrollTop, this.maxScrollTop()) }
  set scrollTop(value) { this.#scrollTop = Math.max(0, Math.min(value, this.maxScrollTop())) }
  maxScrollTop() { return Math.max(0, this.scrollHeight - this.clientHeight) }

  append(...children) {
    for (const child of children) {
      child.parentNode = this
      this.children.push(child)
      if (this.isConnected) child.connect(true)
    }
    return this
  }

  remove() {
    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(child => child !== this)
    this.parentNode = null
    this.connect(false)
  }

  connect(connected) {
    this.isConnected = connected
    if (!connected) this.#document.blurIfActive(this)
    for (const child of this.children) child.connect(connected)
  }

  contains(other) {
    return other === this || this.children.some(child => child.contains(other))
  }

  // Refuses exactly what a browser refuses, and counts the attempts that
  // landed, so a test can tell "focused once" from "focused on every frame".
  focus() {
    if (!this.isConnected || this.disabled || this.getClientRects().length === 0) return
    this.focusCount += 1
    this.#document.activeElement = this
  }

  matches(selector) {
    return selector.split(",").some(simple => matchesSimple(this, simple))
  }

  descendants() {
    return this.children.flatMap(child => [child, ...child.descendants()])
  }

  querySelectorAll(selector) {
    return this.descendants().filter(el => el.matches(selector))
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null
  }
}

// Observers and animation frames that run when the test says, not on a
// schedule. Each `MutationObserver`/`ResizeObserver` the hook constructs is
// kept so a test can fire its callback the way the browser would after a
// patch or a layout change.
export function fakeBrowser() {
  const frames = []
  const mutationObservers = []
  const resizeObservers = []
  const errors = []

  const observerClass = registry =>
    class {
      constructor(callback) {
        this.callback = callback
        this.targets = []
        registry.push(this)
      }
      observe(target) { this.targets.push(target) }
      disconnect() { this.targets = [] }
      trigger() { this.callback([], this) }
    }

  const document = {
    ...eventTarget(),
    body: null,
    documentElement: null,
    activeElement: null,
    blurIfActive(el) {
      if (this.activeElement && el.contains(this.activeElement)) this.activeElement = this.body
    },
    getElementById(id) { return this.querySelector(`#${id}`) },
    querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector) },
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null },
  }
  document.documentElement = new FakeElement(document, {tag: "html"})
  document.documentElement.isConnected = true
  document.body = new FakeElement(document, {tag: "body"})
  document.documentElement.append(document.body)
  document.activeElement = document.body

  const window = {
    ...eventTarget(),
    requestAnimationFrame(callback) { frames.push(callback) },
  }

  return {
    document,
    window,
    mutationObservers,
    resizeObservers,
    errors,
    el: options => new FakeElement(document, options),
    // Runs the frames queued so far; a callback that queues another frame
    // waits for the next call, as it would for the next paint.
    nextFrame() {
      const due = frames.splice(0)
      for (const callback of due) callback()
    },
    context: {
      document,
      window,
      Element: FakeElement,
      MutationObserver: observerClass(mutationObservers),
      ResizeObserver: observerClass(resizeObservers),
      console: {error: message => errors.push(message)},
    },
  }
}
