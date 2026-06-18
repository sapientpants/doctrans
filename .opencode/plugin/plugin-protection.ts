export const PluginProtection = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if ((input.tool === "edit" || input.tool === "write") &&
          output.args.filePath &&
          output.args.filePath.includes(".opencode/plugin")) {
        throw new Error("🚫 Cannot modify files in .opencode/plugin/ directory")
      }
    },
  }
}
