import assert from "node:assert/strict"
import { test } from "node:test"

const cases = [
  ["bash", { command: "git status" }, false],
  ["bash", { command: "git clean -fd" }, true],
  ["bash", { command: "rm -rf build" }, true],
  ["bash", { command: "mix test" }, false],
  ["powershell", { command: "Remove-Item -Recurse tmp" }, true],
  ["read", { path: "lib/foo.ex" }, false],
  ["bash", {}, false],
]

async function checkAdapter(url) {
  const adapter = await import(url)
  let handler
  adapter.default({ on: (event, callback) => {
    if (event === "tool_call") handler = callback
  } })
  assert.equal(typeof handler, "function", "adapter must register a tool_call handler")

  const context = { hasUI: false, ui: { notify() {} } }
  for (const [toolName, input, blocked] of cases) {
    const result = await handler({ type: "tool_call", toolCallId: "test", toolName, input }, context)
    assert.ok(result === undefined || (result !== null && typeof result === "object"),
      "adapter returned a malformed result")
    assert.equal(result?.block === true, blocked, `${toolName}: ${JSON.stringify(input)}`)
    if (blocked) assert.ok(typeof result.reason === "string" && result.reason.length > 0)
  }
}

test("the installed adapter enforces the command policy", async () => {
  await checkAdapter(new URL("../.pi/extensions/block-dangerous-commands.ts", import.meta.url).href)
})

test("a missing adapter fails validation", async () => {
  await assert.rejects(checkAdapter(new URL("./missing-pi-adapter.mjs", import.meta.url).href),
    { code: "ERR_MODULE_NOT_FOUND" })
})

const brokenAdapters = [
  ["syntax error", "export default function (", SyntaxError],
  ["no handler", "export default function () {}", /must register/],
  ["handler crash", "export default pi => pi.on('tool_call', () => { throw Error('fixture crash') })",
    /fixture crash/],
  ["malformed result", "export default pi => pi.on('tool_call', () => 'allow')", /malformed result/],
  ["allows every command", "export default pi => pi.on('tool_call', () => undefined)", /git clean/],
]

for (const [name, source, error] of brokenAdapters) {
  test(`a broken adapter fails validation: ${name}`, async () => {
    const url = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
    await assert.rejects(checkAdapter(url), error)
  })
}
