#!/usr/bin/env bash
# Hook to prevent git commands with --no-verify flag from being executed.
# This ensures all git hooks and verification steps are properly executed.

# Read JSON input from stdin
input_json=$(cat)

# Extract tool_name and command using jq
# If jq fails or fields are missing, fail open (exit 0)
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool_name=$(echo "$input_json" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
command_str=$(echo "$input_json" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only process Bash tool calls
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

# Check if it's a git command
if [[ ! "$command_str" =~ git ]]; then
  exit 0
fi

# Remove quoted strings to avoid false positives
# First, remove single-quoted strings
cleaned_cmd=$(echo "$command_str" | sed "s/'[^']*'//g")
# Then, remove double-quoted strings
cleaned_cmd=$(echo "$cleaned_cmd" | sed 's/"[^"]*"//g')

# Check for --no-verify flag (with word boundaries)
if echo "$cleaned_cmd" | grep -qE '(^|[[:space:]])--no-verify($|=|[[:space:]])'; then
  echo "Error: Git commands with --no-verify flag are not allowed." >&2
  echo "This ensures all git hooks and verification steps are properly executed." >&2
  echo "Please run the git command without the --no-verify flag." >&2
  exit 2
fi

# (Removed invalid -n check; -n is not a short form for --no-verify in git)

# Allow the command to proceed
exit 0
