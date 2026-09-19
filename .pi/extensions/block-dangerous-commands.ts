/**
 * Refuses the same destructive commands as the other agents: work-destroying,
 * history-rewriting, and irreversibly-publishing shell commands.
 *
 * The rule table is deliberately NOT repeated here. scripts/command-policy.sh is the
 * only copy of it, shared with Claude Code, opencode and Codex; this extension feeds
 * it the same JSON they send and turns exit 2 into a blocked tool call. A rule added
 * there applies to every agent at once.
 *
 * Covers the `bash` and `powershell` tools -- the two that execute a command string.
 * It does NOT cover `user_bash`, which is you typing a command yourself: the policy
 * exists to stop an agent acting on its own initiative, not to second-guess a human
 * at their own prompt.
 *
 * Project-local extensions load only after the project is trusted, and non-interactive
 * runs (-p, --mode json, --mode rpc) skip untrusted project resources entirely. Run
 * /trust once in an interactive session, or this guard silently is not there.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"

function findPolicy(): string | undefined {
  const candidates = [
    resolve(dirname(fileURLToPath(import.meta.url)), "../../scripts/command-policy.sh"),
    resolve(process.cwd(), "scripts/command-policy.sh"),
  ]
  return candidates.find((path) => existsSync(path))
}

export default function (pi: ExtensionAPI) {
  const policy = findPolicy()

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash" && event.toolName !== "powershell") return undefined

    const command = event.input.command
    if (typeof command !== "string" || command === "") return undefined

    // Fail open when the policy cannot run at all -- a missing or unexecutable script
    // must not wedge every command. Say so rather than failing silently: a guard that
    // has quietly stopped guarding is worse than no guard.
    if (!policy) {
      console.error("block-dangerous-commands: scripts/command-policy.sh not found; command allowed.")
      return undefined
    }

    const result = spawnSync(policy, {
      input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }),
      encoding: "utf8",
      timeout: 10_000,
    })

    if (result.error || result.status === null) {
      console.error(
        `block-dangerous-commands: policy did not run (${result.error?.message ?? "no exit status"}); command allowed.`,
      )
      return undefined
    }

    if (result.status === 2) {
      const reason = result.stderr.trim()
      if (ctx.hasUI) ctx.ui.notify("Command refused by the project command policy", "warning")
      return { block: true, reason }
    }

    return undefined
  })
}
