import type { Plugin } from "@opencode-ai/plugin"

export const BlockGitNoVerify: Plugin = async () => ({
  "tool.execute.before": async (input, output) => {
    // Only intercept bash tool (maps Claude's .tool_name == "Bash")
    if (input.tool !== "bash") return

    const command = output.args?.command
    if (typeof command !== "string") return

    // Only process commands that contain 'git' (Claude: $command =~ git)
    if (!/\bgit\b/.test(command)) return

    // Strip quoted strings (single then double) — replicates the Claude hook's
    // sed: `s/'[^']*'//g` followed by `s/"[^"]*"//g`
    const stripped = command
      .replace(/'[^']*'/g, "")
      .replace(/"[^"]*"/g, "")

    // Check for --no-verify (word-bounded), matching Claude's grep -qP:
    // (^|[[:space:]])--no-verify($|=|[[:space:]])
    // In JS: (^|[ \t])--no-verify($|[= \t])
    const noVerifyPattern = /(^|[ \t])--no-verify($|[= \t])/
    if (noVerifyPattern.test(stripped)) {
      throw new Error(
        "BlockGitNoVerify: git --no-verify detected and blocked.\n" +
          "git -n is not a short form for --no-verify.\n" +
          "Please commit with verification as expected."
      )
    }
  },
})

export default BlockGitNoVerify
