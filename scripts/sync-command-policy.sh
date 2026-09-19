#!/usr/bin/env bash
# Installs the command policy into Codex's global configuration, and reports when
# the installed copy has drifted from this repository.
#
# Codex reads hooks and execpolicy rules from CODEX_HOME (default ~/.codex) only --
# there is no per-project equivalent of .claude/settings.json or .opencode/plugins.
# So unlike the other two agents, which run scripts/command-policy.sh out of the
# checkout, Codex needs its own copy outside the repository. That copy can go stale;
# `--check` is what notices.
#
#   sync-command-policy.sh --check     compare, report, change nothing (exit 1 on drift)
#   sync-command-policy.sh --install   write, after backing up every file it touches
#
# The reference this policy follows (github.com/vanzan01/codex-protect) embeds its
# rules in a `bun -e` one-liner. Bun is not installed here, and substituting a
# runtime silently would be worse than not installing, so the hook calls the same
# shell script the other agents use.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
codex_home=${CODEX_HOME:-$HOME/.codex}

src_policy="$repo_root/scripts/command-policy.sh"
src_rules="$repo_root/.codex/dangerous-commands.rules"

dst_policy="$codex_home/hooks/command-policy.sh"
dst_rules="$codex_home/rules/default.rules"
dst_hooks="$codex_home/hooks.json"

begin="# BEGIN DOCTRANS COMMAND POLICY"
end="# END DOCTRANS COMMAND POLICY"
status_message="Checking doctrans command policy"

mode=${1:-}
case "$mode" in
  --check|--install) ;;
  *) printf 'usage: %s --check|--install\n' "$0" >&2; exit 64 ;;
esac

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -f "$src_policy" ] && [ -f "$src_rules" ] || { echo "sources missing from $repo_root" >&2; exit 1; }

drift=0
note() { printf '  %-8s %s\n' "$1" "$2"; }

# --- the policy script ------------------------------------------------------
if [ -f "$dst_policy" ] && cmp -s "$src_policy" "$dst_policy"; then
  note ok "$dst_policy"
else
  drift=1
  note DRIFT "$dst_policy"
fi

# --- the native rules block -------------------------------------------------
installed_block=""
if [ -f "$dst_rules" ]; then
  installed_block=$(awk -v b="$begin" -v e="$end" '$0==b{f=1} f{print} $0==e{f=0}' "$dst_rules")
fi
if [ "$installed_block" = "$(cat "$src_rules")" ]; then
  note ok "$dst_rules (policy block)"
else
  drift=1
  note DRIFT "$dst_rules (policy block)"
fi

# --- the hook group ---------------------------------------------------------
hook_command="\"$dst_policy\" --json"
installed_hook=""
if [ -f "$dst_hooks" ]; then
  installed_hook=$(jq -r --arg m "$status_message" \
    'first(.hooks.PreToolUse[]?.hooks[]? | select(.statusMessage == $m) | .command) // ""' \
    "$dst_hooks" 2>/dev/null || echo "")
fi
if [ "$installed_hook" = "$hook_command" ]; then
  note ok "$dst_hooks (PreToolUse group)"
else
  drift=1
  note DRIFT "$dst_hooks (PreToolUse group)"
fi

if [ "$mode" = --check ]; then
  [ "$drift" -eq 0 ] && echo "installed policy matches the repository" || echo "installed policy differs from the repository"
  exit "$drift"
fi

# --- install ----------------------------------------------------------------
stamp=$(date +%Y%m%d-%H%M%S)
# Must not end on a false test: under `set -e` a function returning 1 aborts the
# script, so a first install (nothing to back up) would exit before writing anything.
backup() {
  if [ -f "$1" ]; then
    cp -p "$1" "$1.bak-$stamp"
    note backup "$1.bak-$stamp"
  fi
}

mkdir -p "$codex_home/hooks" "$codex_home/rules"

backup "$dst_policy"
cp "$src_policy" "$dst_policy"
chmod +x "$dst_policy"
note wrote "$dst_policy"

# Replace only the marked block; everything else in default.rules is the user's.
backup "$dst_rules"
tmp=$(mktemp)
if [ -f "$dst_rules" ]; then
  awk -v b="$begin" -v e="$end" '$0==b{f=1;next} $0==e{f=0;next} !f{print}' "$dst_rules" > "$tmp"
fi
if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
cat "$src_rules" >> "$tmp"
mv "$tmp" "$dst_rules"
note wrote "$dst_rules"

# Replace only our matcher group; every other hook group is the user's. Codex
# requires hooks.PreToolUse to be an array -- an object wrapper fails at startup.
backup "$dst_hooks"
tmp=$(mktemp)
existing='{"hooks":{"PreToolUse":[]}}'
[ -f "$dst_hooks" ] && existing=$(cat "$dst_hooks")
printf '%s' "$existing" | jq \
  --arg cmd "$hook_command" --arg msg "$status_message" '
    .hooks //= {} |
    .hooks.PreToolUse = (
      [ (.hooks.PreToolUse // [])[]
        | select(any(.hooks[]?; .statusMessage == $msg) | not) ]
      + [{
          matcher: "^Bash$",
          hooks: [{
            type: "command",
            command: $cmd,
            commandWindows: $cmd,
            timeout: 10,
            statusMessage: $msg
          }]
        }]
    )' > "$tmp"
mv "$tmp" "$dst_hooks"
note wrote "$dst_hooks"

echo
echo "Installed. Two steps only you can do:"
echo "  1. codex        then /hooks, review the '$status_message' hook, and trust it"
echo "  2. restart the Codex app and any running Codex sessions"
echo "Then verify with:  doctrans-policy-probe   (must be refused)"
