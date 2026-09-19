import type { Plugin } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"

// Refuses the same operations as Claude Code, pi and Codex do: work-destroying,
// history-rewriting, and irreversibly-publishing commands.
//
// The rule table is deliberately NOT repeated here. scripts/command-policy.sh is
// the only copy; this plugin feeds it the same JSON the other two agents send and
// turns exit 2 into the thrown error opencode expects. A rule added there applies
// to all three agents at once, which is the whole point -- the previous split, a
// JS plugin next to a shell hook, is how the two drifted to different rules.
//
// This replaces block-git-no-verify.js, whose single rule is now one line of that
// table.

const POLICY = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../scripts/command-policy.sh",
)

export const BlockDangerousCommands: Plugin = async () => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "bash") return

    const command = output.args?.command
    if (typeof command !== "string" || command === "") return

    const result = spawnSync(POLICY, {
      input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }),
      encoding: "utf8",
      timeout: 10_000,
    })

    // Fail open when the policy cannot run at all -- a missing or unexecutable
    // script must not wedge every bash call. It is reported rather than silent,
    // because a guard that has quietly stopped guarding is worse than none.
    if (result.error || result.status === null) {
      console.error(
        `BlockDangerousCommands: policy did not run (${result.error?.message ?? "no exit status"}); command allowed.`,
      )
      return
    }

    if (result.status === 2) {
      throw new Error(result.stderr.trim())
    }
  },
})

export default BlockDangerousCommands
