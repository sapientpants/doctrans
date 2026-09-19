#!/usr/bin/env bash
# Regression tests for the command policy, both layers:
#
#   layer 1  .codex/dangerous-commands.rules   via `codex execpolicy check` (skipped
#            when the codex CLI is absent; only prefix-expressible cases apply)
#   layer 2  scripts/command-policy.sh          the full-command matcher every agent uses
#   layer 3  .pi/extensions/…                   pi's adapter, loaded and driven for real
#            (skipped without node; needs a node new enough to strip TS types)
#
# The cases live in this file rather than on a command line on purpose: a policy
# this strict blocks its own test invocations when the dangerous command is passed
# as an argument to something else. Reading them from here keeps the harness
# runnable without weakening the thing it tests.
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
policy="$repo_root/scripts/command-policy.sh"
rules="$repo_root/.codex/dangerous-commands.rules"

# Scratch repositories on known branches. A bare `git push` names no branch, so the
# policy resolves the current one -- which makes any such case depend on where the
# harness happens to be run from. Pinning the branch is the difference between a test
# and a coin flip: this suite passed on a feature branch and failed on main before it.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mk_repo() { # dir branch
  git init -q -b "$2" "$1"
  git -C "$1" -c user.email=policy@test -c user.name=policy commit -q --allow-empty -m init
}
mk_repo "$scratch/on-main" main
mk_repo "$scratch/on-feature" feature

pass=0; fail=0
report() { # expected actual description
  if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  ok    %-6s %s\n' "$2" "$3"
  else fail=$((fail+1)); printf '  FAIL  want=%s got=%s  %s\n' "$1" "$2" "$3"; fi
}

shell_policy() { # command -> block|allow
  printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | "$policy" >/dev/null 2>&1
  [ "$?" -eq 2 ] && echo block || echo allow
}

shell_policy_in() { # project_dir command -> block|allow
  printf '%s' "$2" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' |
    CLAUDE_PROJECT_DIR="$1" "$policy" >/dev/null 2>&1
  [ "$?" -eq 2 ] && echo block || echo allow
}

native_policy() { # tokens... -> block|allow
  local out
  out=$(codex execpolicy check -r "$rules" "$@" 2>/dev/null) || true
  case "$out" in *'"decision":"forbidden"'*) echo block ;; *) echo allow ;; esac
}

echo "layer 2: scripts/command-policy.sh"
while IFS='|' read -r want cmd; do
  [ -z "${want// }" ] && continue
  case "$want" in \#*) continue ;; esac
  report "$want" "$(shell_policy "$cmd")" "$cmd"
done <<'CASES'
block|git commit --no-verify -m x
block|git commit -n -m x
block|git reset --hard HEAD~1
block|git clean -fd
block|git restore lib/foo.ex
block|git checkout -- lib/foo.ex
block|git checkout .
block|git stash drop
block|git rebase -i main
block|git commit --amend --no-edit
block|git branch -D feature
block|git tag -d v1.0.0
block|git push --force origin feature
block|git push -f
block|git push --force-with-lease
block|git push origin --delete feature
block|git push origin :feature
block|git push --mirror
block|git push origin main
block|git remote set-url origin git@github.com:x/y.git
block|git branch -u origin/feature
block|gh api -X DELETE repos/x/y
block|gh release delete v1
block|gh release upload v1 file.tar
block|rm -rf build
block|rm -r build
block|rm -fr build
block|rmdir emptydir
block|sudo rm /etc/hosts
block|mix ecto.drop
block|mix ecto.reset
block|mix deps.clean --all
block|docker compose down -v
block|docker compose down --volumes
block|docker volume rm doctrans_pgdata
block|docker system prune
block|cd sub && rm -rf .
block|make build; rm -r dist
allow|git status
allow|git status --short
allow|git add --all
allow|git commit -m "fix(x): a thing"
allow|git push origin feature-branch
allow|git push -u origin chore/policy
allow|git checkout -b chore/new
allow|git checkout main
allow|git switch -c feature --track origin/feature
allow|git fetch origin
allow|git pull
allow|git log --oneline -5
allow|git diff origin/main...HEAD
allow|gh pr merge 132 --squash
allow|gh pr list --state merged
allow|gh api repos/x/y --jq .name
allow|gh run list --limit 5
allow|mix test
allow|mix precommit
allow|mix deps.get
allow|docker compose up -d db
allow|docker compose down
allow|rm stale.log
allow|ls -la
CASES

echo
echo "layer 2: a bare push resolves the branch it would land on"
report block "$(shell_policy_in "$scratch/on-main" 'git push')" 'bare push, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git push origin')" 'push naming only a remote, repo on main'
report allow "$(shell_policy_in "$scratch/on-feature" 'git push')" 'bare push, repo on a feature branch'
report allow "$(shell_policy_in "$scratch/on-feature" 'git push origin')" 'push naming only a remote, repo on a feature branch'
report allow "$(shell_policy_in "$scratch/on-main" 'git push origin some-feature')" 'explicit feature target, repo on main'

echo
echo "layer 2: data must not be mistaken for commands"
report block "$(shell_policy 'psql -c "DROP TABLE documents"')" 'psql -c "DROP TABLE documents"'
report allow "$(shell_policy 'git commit -m "feat(db): drop table legacy_pages in a migration"')" 'commit message naming DROP TABLE'
report allow "$(shell_policy 'echo "never run rm -rf /" >> notes.md')" 'quoted prose naming rm -rf'
report allow "$(shell_policy "$(printf 'git commit -F - <<%sEOF%s\nwhy rm -rf and git push --force are refused\nEOF' "'" "'")")" 'heredoc commit message naming the rules'

echo
if command -v node >/dev/null 2>&1 && [ -f "$repo_root/.pi/extensions/block-dangerous-commands.ts" ]; then
  echo "layer 3: pi extension adapter"
  cat > "$scratch/pi-check.mjs" <<'PICHECK'
const ext = process.argv[2]
const mod = await import(ext)
let handler
mod.default({ on: (evt, fn) => { if (evt === "tool_call") handler = fn } })
if (!handler) { console.log("no-handler"); process.exit(0) }
const ctx = { hasUI: false, ui: { notify() {} } }
const cases = [
  ["bash", { command: "git status" }],
  ["bash", { command: "git clean -fd" }],
  ["bash", { command: "rm -rf build" }],
  ["bash", { command: "mix test" }],
  ["powershell", { command: "Remove-Item -Recurse tmp" }],
  ["read", { path: "lib/foo.ex" }],
  ["bash", {}],
]
const out = []
for (const [toolName, input] of cases) {
  const r = await handler({ type: "tool_call", toolCallId: "t", toolName, input }, ctx)
  out.push(r?.block ? "block" : "allow")
}
console.log(out.join(" "))
PICHECK
  # Node must be new enough to strip TypeScript types; older ones just fail the import.
  pi_out=$(node "$scratch/pi-check.mjs" "$repo_root/.pi/extensions/block-dangerous-commands.ts" 2>/dev/null || echo "unavailable")
  if [ "$pi_out" = unavailable ] || [ "$pi_out" = no-handler ]; then
    echo "  skipped (node could not load the extension: $pi_out)"
  else
    set -- $pi_out
    report allow "$1" 'pi: bash git status'
    report block "$2" 'pi: bash git clean -fd'
    report block "$3" 'pi: bash rm -rf build'
    report allow "$4" 'pi: bash mix test'
    report block "$5" 'pi: powershell Remove-Item -Recurse'
    report allow "$6" 'pi: read tool is not gated'
    report allow "$7" 'pi: bash call with no command'
  fi
else
  echo "layer 3: skipped (node or the pi extension is absent)"
fi

echo
if command -v codex >/dev/null 2>&1; then
  echo "layer 1: codex execpolicy against .codex/dangerous-commands.rules"
  report block "$(native_policy doctrans-policy-probe)" 'doctrans-policy-probe (liveness probe)'
  report block "$(native_policy git reset --hard)" 'git reset --hard'
  report block "$(native_policy git clean -fd)" 'git clean -fd'
  report block "$(native_policy git rebase main)" 'git rebase main'
  report block "$(native_policy git push --force)" 'git push --force'
  report block "$(native_policy git commit --no-verify)" 'git commit --no-verify'
  report block "$(native_policy git remote set-url origin x)" 'git remote set-url'
  report block "$(native_policy rm -rf build)" 'rm -rf build'
  report block "$(native_policy rmdir d)" 'rmdir'
  report block "$(native_policy mix ecto.drop)" 'mix ecto.drop'
  report block "$(native_policy docker volume rm v)" 'docker volume rm'
  report block "$(native_policy gh api -X DELETE repos/x/y)" 'gh api -X DELETE'
  report allow "$(native_policy git status)" 'git status'
  report allow "$(native_policy git push origin feature)" 'git push origin feature'
  report allow "$(native_policy gh pr merge 1 --squash)" 'gh pr merge'
  report allow "$(native_policy mix test)" 'mix test'
  report allow "$(native_policy rm stale.log)" 'rm stale.log'
else
  echo "layer 1: skipped (codex CLI not installed)"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
