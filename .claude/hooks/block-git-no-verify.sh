#!/usr/bin/env bash
# Blocks `git ... --no-verify`, which skips the pre-commit and commit-msg hooks
# that .pre-commit-config.yaml defines as the quality gate. The gate is the only
# thing standing between a local commit and CI, so skipping it locally just moves
# the failure to the pull request.
#
# .opencode/plugins/block-git-no-verify.js enforces the same rule for opencode.
# Keep the two in step -- with the exception noted at strip_data below, which the
# plugin does not implement yet.
#
# PreToolUse hook on Bash. Reads the tool call as JSON on stdin; exit 2 blocks the
# call and returns stderr to Claude.
set -uo pipefail

# Remove the parts of a command that are data rather than flags, so that text
# *about* the flag does not read as a use of it. Heredoc bodies matter as much as
# quoted strings here: a commit message written with `git commit -F - <<'EOF'` is
# unquoted, and warning people off the flag is exactly when one says its name.
strip_data() {
  awk '
    delim != "" {
      line = $0
      sub(/^[ \t]+/, "", line)       # <<- strips leading tabs from the terminator
      if (line == delim) delim = ""
      next                           # drop the body and its terminator
    }
    {
      if (match($0, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", delim)
        gsub(/["'"'"']/, "", delim)
      }
      print                          # the line opening the heredoc is still command
    }
  ' | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g'
}

command=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

# Only inspect git commands.
printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_-])git($|[^[:alnum:]_-])' || exit 0

if printf '%s' "$command" | strip_data |
   grep -qE '(^|[[:space:]])--no-verify($|=|[[:space:]])'; then
  cat >&2 <<'MSG'
Blocked: git --no-verify skips the pre-commit and commit-msg hooks.

Those hooks are this project's quality gate (.pre-commit-config.yaml), and CI
runs the same checks -- skipping them locally only defers the failure.

Fix what the gate reports and commit again. Note `git -n` is not a short form
for the flag.
MSG
  exit 2
fi

exit 0
