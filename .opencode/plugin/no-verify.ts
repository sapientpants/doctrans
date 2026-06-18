export const NoVerifyPlugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool === "bash" && output.args.command.includes("git") && output.args.command.includes("--no-verify")) {
        throw new Error("git --no-verify is not allowed. Remove --no-verify and re-run the command.")
      }
    },
  }
}
