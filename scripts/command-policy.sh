#!/usr/bin/env bash
# Command policy for the Bash tool: refuse operations that destroy work, rewrite
# history, or change published state in ways nobody can undo.
#
# Modelled on github.com/vanzan01/codex-protect, adapted in three ways:
#
#   * Publishing is narrowed to the irreversible half. codex-protect forbids every
#     `git push`, `gh pr merge` and `gh api` write; here an ordinary push to a
#     feature branch and a PR merge are how the work actually ships, so only force,
#     delete, mirror, direct-to-main and release mutation are refused.
#   * Tracked-branch creation (`git checkout -b … origin/…`, `git switch -c … --track`)
#     is not refused. It creates a ref and destroys nothing.
#   * This repository's own irreversibles are added: the remote-URL rule from
#     AGENTS.md, and the database and volume operations that would take the
#     pgdata volume with them.
#
# One policy, every agent. This script is the only copy of the rule table:
#
#   Claude Code  .claude/settings.json runs it as a PreToolUse hook on Bash
#   opencode     .opencode/plugins/block-dangerous-commands.js spawns it
#   pi           .pi/extensions/block-dangerous-commands.ts spawns it on tool_call
#   Codex        ~/.codex/hooks.json runs it with --json, backed by native
#                forbidden rules in ~/.codex/rules/default.rules
#
# Codex's config is global, so its copy lives under ~/.codex and has to be re-synced
# when this file changes; scripts/sync-command-policy.sh does that and reports drift.
#
# Reads the tool call as JSON on stdin. Two output modes, because the agents differ:
#
#   (default)  exit 2 with the reason on stderr        -- Claude Code, opencode
#   --json     a PreToolUse deny decision on stdout    -- Codex
set -uo pipefail

output=exit2
case "${1:-}" in
  --json) output=json ;;
  "") ;;
  *) printf 'usage: %s [--json]\n' "$0" >&2; exit 64 ;;
esac

command=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

# ---------------------------------------------------------------------------
# Policy. Runs as one awk pass: strip the parts of the command that are data,
# then test the rules against what remains.
#
# Stripping matters as much as the rules. A command that *mentions* `rm -rf` in a
# commit message or writes it into a script is not a command that runs it, and a
# guard that cannot tell the difference blocks the documentation of its own rules
# -- which is exactly how the first version of this hook rejected its own commit.
# Quoted strings and heredoc bodies are therefore removed before matching. The
# stripping has to err towards keeping: whatever it wrongly removes is a line no
# rule will ever see, so a heredoc is only recognised where the shell would
# recognise one, and a body that is never terminated is treated as command.
#
# Every rule matches ` word `, so the text is normalised until each token the
# shell would see has a space on both sides: a separator glued to a word
# (`true;git reset --hard`, `$(rm -rf build)`), a path on the command (`/bin/rm`)
# and an alias-defeating backslash (`\rm`) are all boundaries to the shell and
# were none to the rules. Separators are kept, so `[^;&|]*` inside a rule still
# stops at one and `git status && rm file` is not read as `git ... rm`.
# ---------------------------------------------------------------------------
read -r -d '' POLICY <<'AWK' || true
function deny(re, msg) {
  if (verdict == "" && match(cmd, re)) verdict = msg
}

# The delimiter of a heredoc opened on this line, or "" when the line opens none.
# Scans the line the way the shell reads it, because a `<<` is only a heredoc
# opener when the shell would treat it as one: not inside quotes, not after a `#`,
# and not the first two characters of a `<<<` here-string. A bare regex over the
# raw line got every one of those wrong, and a false opener was worse than a
# missed one -- it put the rest of the command inside a body that never closed,
# where no rule could see it.
#
# `q`, `dq` and `quotes` are the globals BEGIN sets below; awk resolves them when
# the function is called, not where it is written.
function heredoc_delim(line,    i, n, c, prev, open_quote, rest, word) {
  n = length(line)
  open_quote = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (open_quote == q)  { if (c == q) open_quote = ""; continue }
    if (open_quote == dq) { if (c == "\\") i++; else if (c == dq) open_quote = ""; continue }
    if (c == "\\") { i++; continue }
    if (c == q || c == dq) { open_quote = c; continue }
    prev = (i == 1) ? " " : substr(line, i - 1, 1)
    if (c == "#" && index(" \t;&|()", prev)) return ""
    if (c != "<" || substr(line, i + 1, 1) != "<") continue
    if (substr(line, i + 2, 1) == "<") { i += 2; continue }   # here-string
    rest = substr(line, i + 2)
    sub(/^-?[ \t]*/, "", rest)                                 # `<<-` and `<< EOF`
    if (!match(rest, "^" quotes "?[A-Za-z_][A-Za-z0-9_]*")) return ""
    word = substr(rest, 1, RLENGTH)
    gsub(quotes, "", word)
    return word
  }
  return ""
}

# Whether the text names a client that would run SQL handed to it. Shared by the
# SQL rule and the heredoc pass so the two lists cannot drift apart.
function names_db_client(text) {
  text = tolower(text)
  return index(text, "psql") || index(text, "dropdb") || index(text, "mysql") || index(text, "docker exec")
}

# A quoted string is data to the command it is handed to -- except when that
# command is a shell. `bash -c "rm -rf build"` and `eval "git reset --hard"` run
# the string, so its quotes come off and the text stays in `cmd` for the rules
# instead of being stripped with every other quoted string. A quote of the other
# kind inside the payload is then stripped on its own, which keeps less than the
# shell runs, but only ever in the safe direction: a rule misses nothing it would
# have seen, and the worst outcome is a refusal.
function unwrap_shell_payloads(    re, start, qc, len) {
  re = "(^|[ \t;&|(`])(/[^ \t]*/)?((ba|z|da|k)?sh[ \t]+-[A-Za-z]*c|eval)[ \t]+" quotes
  while (match(cmd, re)) {
    start = RSTART + RLENGTH - 1                  # the opening quote
    qc = substr(cmd, start, 1)
    len = index(substr(cmd, start + 1), qc)       # distance to the closing quote
    if (len == 0) return                          # never closed: the strip leaves it too
    cmd = substr(cmd, 1, start - 1) substr(cmd, start + 1, len - 1) substr(cmd, start + len + 1)
  }
}

# Gives every token a space on each side, which is what the rules match on. Runs
# after the quoted strings are gone, so a `;` or `(` inside a commit message is
# not read as a separator. Separators stay in the text, spaced, so `[^;&|]*` in
# a rule still stops at them.
function normalise_tokens() {
  while (match(cmd, /\\[A-Za-z0-9_\/]/))            # `\rm` is `rm` to the shell
    cmd = substr(cmd, 1, RSTART - 1) substr(cmd, RSTART + 1)
  gsub(/[;&|(){}`]+/, " & ", cmd)                  # `;git` -> ` ; git`, `$(rm` -> `$ ( rm`
  gsub(/[ \t]+/, " ", cmd)
  cmd = " " cmd " "
  while (match(cmd, / \/[^ ]*\/[A-Za-z]/))          # ` /bin/rm` -> ` rm`
    cmd = substr(cmd, 1, RSTART) substr(cmd, RSTART + RLENGTH - 1)
}

BEGIN {
  q  = sprintf("%c", 39)   # '
  dq = sprintf("%c", 34)   # "
  quotes = "[" q dq "]"
}

# Inside a heredoc. The body is data to the shell, so it stays out of `cmd` -- and
# out of `raw` too, unless the opening line hands it to a database client:
# `psql <<SQL` runs the body, so the SQL rule has to see it, while a body written
# to a file or a commit message is prose whatever it says. The body is also kept
# aside until the terminator arrives. If it never does, this script cannot tell a
# heredoc the shell closes at end of input from an opener it misread, and only one
# of those is safe to skip: END hands the lines back to `cmd` and `raw`.
delim != "" {
  line = $0
  sub(/^[ \t]+/, "", line)          # <<- allows a tab-indented terminator
  if (line == delim) { delim = ""; body = ""; next }
  body = body " " $0
  if (body_runs_sql) raw = raw " " $0
  next
}
{
  delim = heredoc_delim($0)        # the opening line itself is command
  body_runs_sql = (delim != "" && names_db_client($0))
  cmd = cmd " " $0
  raw = raw " " $0                 # same lines, quotes intact, for the SQL rule
}

END {
  if (delim != "") {                  # an unterminated heredoc hides nothing
    cmd = cmd body
    if (!body_runs_sql) raw = raw body
  }
  unwrap_shell_payloads()
  gsub(q "[^" q "]*" q, "", cmd)      # single-quoted strings
  gsub(dq "[^" dq "]*" dq, "", cmd)   # double-quoted strings
  normalise_tokens()
  rawlc = tolower(raw)

  # --- Verification bypass ------------------------------------------------
  deny(" git [^;&|]*--no-verify[ =]", "git --no-verify skips the pre-commit and commit-msg hooks")
  deny(" git commit [^;&|]*-n ",      "git commit -n skips the commit-msg hook")

  # --- Discards uncommitted work ------------------------------------------
  deny(" git reset [^;&|]*--hard ",   "git reset --hard discards uncommitted work")
  deny(" git clean ",                 "git clean permanently removes untracked files")
  deny(" git restore ",               "git restore discards working-tree changes")
  deny(" git checkout (--|\\.) ",     "git checkout -- discards working-tree changes")
  deny(" git (checkout|switch) [^;&|]*(-f|--force|--discard-changes) ", "a forced checkout discards working-tree changes")
  deny(" git stash (drop|clear) ",    "git stash drop/clear destroys stashed work")

  # --- Rewrites history ---------------------------------------------------
  deny(" git rebase ",                "git rebase rewrites history")
  deny(" git commit [^;&|]*--amend ", "git commit --amend rewrites a commit")
  deny(" git (filter-branch|filter-repo) ", "history rewriting is refused")
  deny(" git reflog expire ",         "expiring the reflog removes the recovery path for rewritten history")
  deny(" git gc [^;&|]*--prune ",     "pruning gc can drop unreferenced objects that are still the only copy")
  deny(" git update-ref -d ",         "deleting a ref directly can orphan commits")
  deny(" git branch [^;&|]*-D ",      "forced branch deletion can drop unmerged commits")
  deny(" git branch [^;&|]*--delete [^;&|]*--force ", "forced branch deletion can drop unmerged commits")
  deny(" git tag [^;&|]*-d ",         "deleting a tag removes a published marker")

  # --- Irreversible publishing --------------------------------------------
  deny(" git push [^;&|]*(--force|--force-with-lease|-f) ", "a force push overwrites published history")
  deny(" git push [^;&|]*--delete ",  "git push --delete removes a remote branch")
  deny(" git push [^;&|]* :[^ ]+ ",   "a colon refspec deletes a remote branch")
  deny(" git push [^;&|]*--mirror ",  "git push --mirror overwrites every remote ref")
  deny(" git push [^;&|]*(main|master) ", "pushing straight to the default branch bypasses review")
  deny(" gh api [^;&|]*(-X|--method)[ =]DELETE ", "a DELETE through the GitHub API is irreversible")
  deny(" gh release (delete|delete-asset|edit|upload) ", "mutating a published release is irreversible")

  # --- Remote configuration (AGENTS.md: never change the remote URL) ------
  deny(" git remote (set-url|add|remove|rename|rm) ", "changing the git remote is forbidden by AGENTS.md")
  deny(" git branch [^;&|]*(--set-upstream-to|-u) ", "changing a branch upstream rewires where work is pushed")

  # --- Recursive deletion -------------------------------------------------
  deny(" rm [^;&|]*(-[A-Za-z]*[rR][A-Za-z]*|--recursive) ", "recursive deletion with rm is refused")
  deny(" rmdir ",                     "rmdir is refused")
  deny(" [Rr]emove-[Ii]tem [^;&|]*(-[Rr]ecurse|-r) ", "recursive PowerShell deletion is refused")
  deny(" sudo rm ",                   "deleting as root is refused")

  # --- This project's data ------------------------------------------------
  deny(" mix ecto\\.(drop|reset) ",   "dropping the database destroys local data")
  deny(" mix deps\\.clean [^;&|]*--all ", "AGENTS.md: deps.clean --all is almost never needed")
  deny(" docker(-| )compose [^;&|]*down [^;&|]*(-v|--volumes) ", "compose down -v deletes the pgdata volume")
  deny(" docker (volume rm|volume prune|system prune) ", "removing docker volumes destroys the database")
  deny(" dropdb ",                    "dropping the database destroys local data")

  # Destructive SQL reaches the client as a quoted argument or a heredoc body, so
  # it is gone from cmd by now -- match the raw text instead. Requiring a database
  # client in the same command keeps prose that merely says "drop table" from
  # tripping this.
  if (verdict == "" &&
      (index(rawlc, "drop database") || index(rawlc, "drop table") || index(rawlc, "truncate table")) &&
      names_db_client(raw))
    verdict = "destructive SQL against the database is refused"

  # --- Whole-machine ------------------------------------------------------
  deny(" mkfs",                       "formatting a filesystem is refused")
  deny(" dd [^;&|]*of=/dev/",         "writing raw to a device is refused")
  deny(" chmod [^;&|]*-R [^;&|]*777 ", "a recursive world-writable chmod is refused")

  if (verdict != "") print verdict
}
AWK

verdict=$(printf '%s\n' "$command" | awk "$POLICY")

# A bare `git push` names no branch, so the rule above cannot see where it lands.
# Resolve the branch instead. Approximate by design: the command may cd elsewhere
# first, and this reads the project checkout.
if [ -z "$verdict" ] && printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_-])git +push'; then
  rest=${command#*push}
  positional=0
  for token in $rest; do
    case "$token" in
      ';'|'&&'|'||'|'|') break ;;
      -*) ;;
      *) positional=$((positional + 1)) ;;
    esac
  done
  if [ "$positional" -le 1 ]; then
    branch=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    case "$branch" in
      main|master) verdict="pushing straight to the default branch bypasses review" ;;
    esac
  fi
fi

[ -n "$verdict" ] || exit 0

reason="Blocked by the command policy: ${verdict}. The rule lives in scripts/command-policy.sh. If this operation is genuinely what is wanted, run it yourself -- the policy deliberately does not let the agent decide that its own case is the exception."

if [ "$output" = json ]; then
  # Codex (and Claude Code) read a decision object on stdout. jq builds it so the
  # reason is escaped properly rather than hand-quoted.
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi

printf '%s\n' "$reason" >&2
exit 2
