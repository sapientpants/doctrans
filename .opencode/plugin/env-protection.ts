import type { Plugin } from "@opencode-ai/plugin"

export const EnvProtection: Plugin = async ({ client }) => {
  return {
    tool: {
      execute: {
        before: async (input, output) => {
          // This runs BEFORE any tool executes
          if (input.tool === "read" &&
              output.args.filePath.includes(".env")) {
            throw new Error("🚫 Cannot read .env files")
          }
        }
      }
    }
  }
}
