import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import vm from "node:vm"

const storageKey = "phx:theme"
const source = name => readFileSync(new URL(`../../assets/js/${name}.js`, import.meta.url), "utf8")

// These small substitutes expose only the browser boundaries used by the real
// modules. No theme selection or synchronization logic is reproduced here.
const eventTarget = () => {
  const handlers = new Map()
  return {
    addEventListener(name, callback) {
      handlers.set(name, [...(handlers.get(name) || []), callback])
    },
    dispatch(name, event = {}) {
      for (const callback of handlers.get(name) || []) callback(event)
    },
  }
}

async function browser({stored, initialTheme, denyRead = false, denyWrite = false} = {}) {
  const attributes = new Map()
  if (initialTheme !== undefined) attributes.set("data-theme", initialTheme)
  const storage = new Map(stored === undefined ? [] : [[storageKey, stored]])
  const buttons = []
  const document = {
    ...eventTarget(),
    documentElement: {
      hasAttribute: name => attributes.has(name),
      getAttribute: name => attributes.get(name) ?? null,
      setAttribute: (name, value) => attributes.set(name, value),
      removeAttribute: name => attributes.delete(name),
    },
    querySelectorAll(selector) {
      assert.equal(selector, "[data-phx-theme]")
      return buttons
    },
    querySelector(selector) {
      assert.equal(selector, "meta[name='csrf-token']")
      return {getAttribute: () => "csrf-test-token"}
    },
  }
  const window = eventTarget()
  const localStorage = {
    getItem(key) {
      if (denyRead) throw new Error("storage denied")
      return storage.get(key) ?? null
    },
    setItem(key, value) {
      if (denyWrite) throw new Error("storage denied")
      storage.set(key, value)
    },
    removeItem(key) {
      if (denyWrite) throw new Error("storage denied")
      storage.delete(key)
    },
  }
  let hooks
  const context = vm.createContext({document, window, localStorage, process: {env: {NODE_ENV: "test"}}})
  const modules = new Map()
  const externals = {
    phoenix_html: {},
    phoenix: {Socket: class {}},
    phoenix_live_view: {
      LiveSocket: class {
        constructor(_url, _socket, options) { hooks = options.hooks }
        connect() {}
      },
    },
    "phoenix-colocated/doctrans": {hooks: {}},
    "../vendor/topbar": {default: {config() {}, show() {}, hide() {}}},
  }
  const load = name => {
    if (!modules.has(name)) modules.set(name, new vm.SourceTextModule(source(name), {context}))
    return modules.get(name)
  }
  const link = async specifier => {
    if (specifier === "./theme_sync") return load("theme_sync")
    assert.ok(Object.hasOwn(externals, specifier), `unexpected dependency: ${specifier}`)
    const exports = externals[specifier]
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [name, value] of Object.entries(exports)) this.setExport(name, value)
    }, {context})
  }
  const theme = load("theme")
  await theme.link(link)
  await theme.evaluate()

  return {
    storage, buttons, document, window,
    theme: () => attributes.get("data-theme"),
    select: value => window.dispatch("phx:set-theme", {target: {dataset: {phxTheme: value}}}),
    addToggles(count = 1) {
      for (let group = 0; group < count; group++) {
        for (const theme of ["system", "light", "dark"]) {
          const attributes = new Map([["aria-pressed", String(theme === "system")]])
          buttons.push({dataset: {phxTheme: theme}, attributes,
            setAttribute: (name, value) => attributes.set(name, value)})
        }
      }
    },
    async loadApp() {
      const app = load("app")
      await app.link(link)
      await app.evaluate()
      return hooks
    },
  }
}

function assertPressed(browser, theme) {
  assert.ok(browser.buttons.length > 0)
  for (const button of browser.buttons) {
    assert.equal(button.attributes.get("aria-pressed"), String(button.dataset.phxTheme === theme))
  }
}

test("saved choice applies before buttons exist and DOMContentLoaded synchronizes all toggles", async () => {
  const page = await browser({stored: "dark"})
  assert.equal(page.theme(), "dark")
  page.addToggles(2)
  page.document.dispatch("DOMContentLoaded")
  assertPressed(page, "dark")
})

test("selecting each theme changes the page, persistence, and pressed state", async () => {
  const page = await browser()
  page.addToggles()
  for (const theme of ["dark", "light", "system"]) {
    page.select(theme)
    assert.equal(page.theme(), theme === "system" ? undefined : theme)
    assert.equal(page.storage.get(storageKey), theme === "system" ? undefined : theme)
    assertPressed(page, theme)
  }
})

test("a theme already rendered by the server is preserved", async () => {
  const page = await browser({stored: "light", initialTheme: "dark"})
  assert.equal(page.theme(), "dark")
  assert.equal(page.storage.get(storageKey), "light")
  page.addToggles()
  page.document.dispatch("DOMContentLoaded")
  assertPressed(page, "dark")
})

test("invalid saved choices are removed at boot", async () => {
  for (const stored of ["undefined", "unknown", "system", ""]) {
    const page = await browser({stored})
    assert.equal(page.theme(), undefined)
    assert.equal(page.storage.has(storageKey), false)
  }
})

test("invalid or non-element selection events restore system mode safely", async () => {
  const page = await browser({stored: "dark"})
  page.addToggles()
  for (const event of [{target: {dataset: {phxTheme: "unknown"}}}, {target: page.window}, {}]) {
    page.select("dark")
    page.window.dispatch("phx:set-theme", event)
    assert.equal(page.theme(), undefined)
    assert.equal(page.storage.has(storageKey), false)
    assertPressed(page, "system")
  }
})

test("storage events update the theme only for the theme key", async () => {
  const page = await browser({stored: "light"})
  page.addToggles()
  page.window.dispatch("storage", {key: "another-key", newValue: "dark"})
  assert.equal(page.theme(), "light")
  for (const value of ["dark", "light", null, "invalid"]) {
    page.window.dispatch("storage", {key: storageKey, newValue: value})
    const expected = ["dark", "light"].includes(value) ? value : "system"
    assert.equal(page.theme(), expected === "system" ? undefined : expected)
    assertPressed(page, expected)
  }
})

test("denied reads and writes do not prevent subsequent theme selection", async () => {
  for (const options of [{denyRead: true}, {denyWrite: true}, {denyRead: true, denyWrite: true}]) {
    const page = await browser(options)
    page.addToggles()
    page.select("dark")
    assert.equal(page.theme(), "dark")
    assertPressed(page, "dark")
    page.select("system")
    assert.equal(page.theme(), undefined)
    assertPressed(page, "system")
  }
})

test("the hook registered by the actual app restores pressed state on mount and patch", async () => {
  const page = await browser({stored: "dark"})
  page.addToggles(2)
  const hooks = await page.loadApp()
  hooks.ThemeToggle.mounted()
  assertPressed(page, "dark")
  for (const button of page.buttons) button.attributes.set("aria-pressed", "false")
  hooks.ThemeToggle.updated()
  assertPressed(page, "dark")
})
