// Loads the real modules under `assets/js` into a `node:vm` context.
//
// esbuild is what resolves these imports in the build, so the tests cannot
// `import` them directly: the specifiers have no extension, `./hooks` means
// `./hooks/index.js`, and `app.js` pulls in packages the harness never
// installs. The loader below resolves the way esbuild does, hands each
// external package a synthetic module, and evaluates everything inside the
// context a test built -- so `document`, `window` and the rest are the fakes
// the test supplied, not Node's absence of them.
import assert from "node:assert/strict"
import {existsSync, readFileSync} from "node:fs"
import vm from "node:vm"

export const assetsDir = new URL("../../assets/js/", import.meta.url)

// Resolves a relative import the way esbuild does for this tree: against the
// importing file, with `.js` implied and a directory standing for its
// `index.js`.
const resolve = (specifier, from) => {
  const base = new URL(specifier, from)
  for (const candidate of [`${base.href}.js`, `${base.href}/index.js`]) {
    if (existsSync(new URL(candidate))) return new URL(candidate)
  }
  throw new Error(`cannot resolve ${specifier} from ${from}`)
}

// The packages `app.js` imports, as the smallest objects that let it evaluate.
// `onLiveSocket` receives the options `app.js` constructs the LiveSocket with,
// which is where the registered hooks are.
export const appExternals = (onLiveSocket = () => {}) => ({
  phoenix_html: {},
  phoenix: {Socket: class {}},
  phoenix_live_view: {
    LiveSocket: class {
      constructor(_url, _socket, options) { onLiveSocket(options) }
      connect() {}
    },
  },
  "phoenix-colocated/doctrans": {hooks: {}},
  "../vendor/topbar": {default: {config() {}, show() {}, hide() {}}},
})

// Returns an `importModule(specifier)` for `context`. Modules are shared across
// calls, so `./theme` and `./app` loaded through the same importer see one
// `theme_sync` and one set of hooks.
export function moduleLoader(context, externals = {}) {
  const modules = new Map()

  const load = url => {
    if (!modules.has(url.href)) {
      const module = new vm.SourceTextModule(readFileSync(url, "utf8"), {context, identifier: url.href})
      modules.set(url.href, module)
    }
    return modules.get(url.href)
  }

  const link = async (specifier, referencing) => {
    if (Object.hasOwn(externals, specifier)) {
      const exports = externals[specifier]
      return new vm.SyntheticModule(Object.keys(exports), function () {
        for (const [name, value] of Object.entries(exports)) this.setExport(name, value)
      }, {context})
    }
    assert.ok(specifier.startsWith("./") || specifier.startsWith("../"), `unexpected dependency: ${specifier}`)
    return load(resolve(specifier, referencing.identifier))
  }

  return async function importModule(specifier) {
    const module = load(resolve(specifier, assetsDir))
    await module.link(link)
    await module.evaluate()
    return module.namespace
  }
}

// A hook object as LiveView instantiates it: the callbacks with `this.el` set.
// `pushEvent` records what the hook asked the server for.
export function mountHook(hook, el) {
  const instance = Object.create(hook)
  instance.el = el
  instance.pushed = []
  instance.pushEvent = (event, payload) => instance.pushed.push([event, payload])
  instance.mounted()
  return instance
}
