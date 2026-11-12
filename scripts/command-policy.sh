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
# (`true;git reset --hard`, `$(rm -rf build)`), a path on the command (`/bin/rm`,
# `./rm`) and an alias-defeating backslash (`\rm`) are all boundaries to the
# shell and were none to the rules. Separators are kept, spaced, so `[^;&|]*`
# inside a rule still stops at one and `git status && rm file` is not read as
# `git ... rm`. A quoted payload handed to a shell (`bash -c "..."`) is a command,
# not data, and is unwrapped before the quoted strings are stripped.
#
# Git gets one more pass, because its command line is looser than the rules can
# be: global options sit between `git` and the subcommand (`git -C . reset
# --hard`), an alias stands in for the subcommand (`git p --force` with
# `alias.p = push`), and short flags cluster (`git push -fu`). The options are
# removed, the alias is expanded from the user's git config, and the rules match
# the flag letter inside a cluster. Git also takes configuration from the command
# itself -- `-c key=value`, `--config-env`, the GIT_CONFIG_* variables -- and two
# settings are rules in their own right: core.hooksPath moves every hook, and
# alias.<name> defines the subcommand the rules key on. Those are read from the
# text before the quotes come off, because a value with a space in it is quoted.
# A rule that reads a push target runs on a second copy of the text in which a
# quoted word is kept rather than stripped, so `git push origin 'HEAD:main'`
# names the branch it would land on.
# ---------------------------------------------------------------------------
read -r -d '' POLICY <<'AWK' || true
# Refuses the command with `msg` when `re` matches `text`, which defaults to the
# stripped command. A rule whose argument is never prose -- a push refspec is a
# ref whether or not it is quoted -- passes `cmdq`, the copy that keeps quoted
# words. The first rule to match wins.
function deny(re, msg, text) {
  if (text == "") text = cmd
  if (verdict == "" && match(text, re)) verdict = msg
}

# The distance from the quote at `i` to the one that closes it, 0 when it is
# never closed.
function quote_span(text, i) {
  return index(substr(text, i + 1), substr(text, i, 1))
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

# Removes `len` characters of `text` starting at `start`.
function cut(text, start, len) {
  return substr(text, 1, start - 1) substr(text, start + len)
}

# Whether a command word hands its arguments on as another command: `sudo
# /bin/rm` runs rm, `env X=1 git` runs git, and so does a shell whose `-c`
# payload has been unwrapped (`bash -c "/bin/rm -rf build"`) or an eval.
function runs_its_arguments(word) {
  return word ~ /^(sudo|doas|command|builtin|exec|env|xargs|nohup|nice|time|timeout|(ba|z|da|k)?sh|eval)$/
}

# Drops the directory from a word that names a command: `/bin/rm`, `./rm`,
# `bin/git`, `~/bin/rm` and `$HOME/bin/git` are all `rm` or `git` to the shell.
# An option such as `--git-dir=/x/rm` is not a command and is left alone.
function strip_path(word) {
  if (word !~ /^-/ && match(word, /\/[A-Za-z][^\/]*$/)) return substr(word, RSTART + 1)
  return word
}

# A quoted string is data to the command it is handed to -- except when that
# command is a shell. `bash -c "rm -rf build"` and `eval "git reset --hard"` run
# the string, so its quotes come off and the text stays visible to the rules
# instead of being stripped with every other quoted string. The whole argument
# word is unwrapped, so `-lc`, `-cx`, `-c --`, `$'...'` and pieces glued together
# (`"r""m -rf build"`, `rm" -rf build"`) all come out as the shell would run them.
# A quote of the other kind inside the payload is then stripped like any other,
# which keeps less than the shell runs but only in the safe direction.
#
# Not covered: a payload held in a variable (`sh -c "$X"`), one fed on stdin
# (`echo ... | bash`), a shell option that takes a value before `-c`
# (`-o pipefail`), and interpreters other than sh/bash/zsh/dash/ksh and eval.
function unwrap_shell_payloads(text,    re, pos, i, c, j) {
  re = "(^|[ \t;&|(`{])([^ \t]*/)?((ba|z|da|k)?sh([ \t]+-[^ \t]*)*[ \t]+-[A-Za-z]*c[A-Za-z]*([ \t]+-[^ \t]*)*|eval)[ \t]+"
  pos = 1
  while (match(substr(text, pos), re)) {
    i = pos + RSTART + RLENGTH - 1               # first character of the payload word
    while (i <= length(text)) {
      c = substr(text, i, 1)
      if (c == "$" && (substr(text, i + 1, 1) == q || substr(text, i + 1, 1) == dq)) {
        text = cut(text, i, 1)                    # `$'...'` quotes like `'...'`
        c = substr(text, i, 1)
      }
      if (c == q || c == dq) {
        j = quote_span(text, i)
        if (j == 0) return text                   # never closed: the strip leaves it too
        text = cut(text, i + j, 1)
        text = cut(text, i, 1)
        i += j - 1
      } else if (c == " " || c == "\t") break
      else if (c == "\\") i += 2
      else i++
    }
    pos = i
  }
  return text
}

# Gives every token a space on each side, which is what the rules match on (see
# the note above the policy). Runs after the quoted strings are gone, so a `;` or
# `(` inside a commit message is not read as a separator. A command's directory
# comes off only where the shell resolves a command: at the start, after a
# separator, after a `VAR=value` prefix, and through a word that runs its
# arguments (`sudo /bin/rm`, `find -exec /bin/rm`) -- an argument that merely
# ends in a rule word (`cat /tmp/rmdir`) stays a path.
function normalise_tokens(text,    tok, n, i, w, out, expect, strip_all) {
  while (match(text, /\\[A-Za-z0-9_\/]/))          # `\rm` is `rm` to the shell
    text = cut(text, RSTART, 1)
  gsub(/[;&|(){}`]+/, " & ", text)                 # `;git` -> ` ; git`, `$(rm` -> `$ ( rm`
  n = split(text, tok, /[ \t]+/)
  out = ""; expect = 1; strip_all = 0
  for (i = 1; i <= n; i++) {
    w = tok[i]
    if (w == "") continue
    if (w ~ /^[;&|(){}`]+$/) { expect = 1; strip_all = 0 }
    else if (w ~ /^-(exec|execdir|ok|okdir)$/) strip_all = 1
    else if (expect && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ;        # `X=1 /bin/rm`: the command is next
    else if (expect) {
      w = strip_path(w); expect = 0
      strip_all = runs_its_arguments(w)
    }
    else if (strip_all) w = strip_path(w)
    out = out " " w
  }
  return out " "
}

# Replaces every quoted string with a single placeholder character. The
# placeholder, not nothing, because the string was a word to the shell and a rule
# that reads words by position must still see one there: `git -c 'x=y' commit
# --amend` has to keep `commit` as its subcommand rather than as the value of
# `-c`. With `keep_words`, a quoted string with no whitespace in it is kept as
# the word the shell would pass (`'HEAD:main'` is a refspec, `"wip"` is a commit
# message, and neither is prose); one with whitespace is prose or a script and
# is replaced like the rest.
function strip_quotes(text, keep_words,    pos, i, j, c, inner, out) {
  out = ""; pos = 1
  while (match(substr(text, pos), quotes)) {
    i = pos + RSTART - 1
    c = substr(text, i, 1)
    j = quote_span(text, i)
    if (j == 0) break                            # never closed: left as it is
    inner = substr(text, i + 1, j - 1)
    out = out substr(text, pos, i - pos)
    out = out ((keep_words && inner != "" && inner !~ /[ \t]/) ? inner : placeholder)
    pos = i + j + 1
  }
  return out substr(text, pos)
}

# Defines a git alias the way git does: the name is case-insensitive, a later
# definition wins, and a name that hides a built-in command is ignored ("aliases
# that hide existing Git commands are ignored", git-config(1)) -- so `alias.push =
# status` cannot turn a force push into something harmless.
function define_alias(name, expansion) {
  name = tolower(name)
  if (!(name in git_commands)) aliases[name] = expansion
}

# Records one configuration setting git would read from the command line or
# the environment. Two are rules: core.hooksPath points the hooks at another
# directory, which is `--no-verify` for every hook at once, and alias.<name>
# defines a subcommand. Git reads the key case-insensitively. With `opaque` the
# value is the name of an environment variable (`--config-env`), which this
# script cannot read: an alias defined that way is refused rather than guessed.
function note_git_setting(setting, opaque,    key, value) {
  key = setting; value = ""
  if (index(setting, "=")) {
    key = substr(setting, 1, index(setting, "=") - 1)
    value = substr(setting, index(setting, "=") + 1)
  }
  key = tolower(key)
  if (key == "core.hookspath") hooks_moved = 1
  else if (key ~ /^alias\.[^.]+$/) {
    if (opaque) alias_unreadable = substr(key, 7)
    else define_alias(substr(key, 7), value)
  }
}

# The shell word that starts at `start`, with its quotes resolved the way the
# shell resolves them, and `word_end` left on the character after it. Used to
# read a value handed to git, which is quoted whenever it holds a space.
function shell_word(text, start,    i, n, c, open_quote, out) {
  n = length(text); out = ""; open_quote = ""
  for (i = start; i <= n; i++) {
    c = substr(text, i, 1)
    if (open_quote != "") {
      if (c == open_quote) open_quote = ""
      else if (c == "\\" && open_quote == dq) out = out substr(text, ++i, 1)
      else out = out c
    }
    else if (c == "$" && (substr(text, i + 1, 1) == q || substr(text, i + 1, 1) == dq)) ;   # `$'...'` quotes like `'...'`
    else if (c == q || c == dq) open_quote = c
    else if (c == "\\") out = out substr(text, ++i, 1)
    else if (index(" \t;&|(){}`", c)) break
    else out = out c
  }
  word_end = i
  return out
}

# The `n` of a `GIT_CONFIG_KEY_n=...` or `GIT_CONFIG_VALUE_n=...` assignment.
function numbered_env(assignment, prefix) {
  return substr(assignment, length(prefix) + 1, index(assignment, "=") - length(prefix) - 1)
}

# Reads every configuration setting git would take from the command: `-c key=val`
# and `--config-env key=VAR` on a git command, and the GIT_CONFIG_PARAMETERS or
# GIT_CONFIG_KEY_n + GIT_CONFIG_VALUE_n variables wherever they are assigned
# (`X=v git ...`, `export X=v`, `env X=v git ...`). A `-c` is only git's when the
# command word is git, through any wrapper (`sudo git -c`): `bash -c`, `psql -c`
# and `grep -c` take their own. Runs on the text before its quotes are stripped,
# because a value with a space in it is quoted and the strip would hide it.
function note_git_settings(text,    n, pos, c, w, prev, at_command, wrapped, on_git, keys, values, k, entries, m, j) {
  n = length(text); pos = 1; prev = ""; at_command = 1; wrapped = 0; on_git = 0
  while (pos <= n) {
    c = substr(text, pos, 1)
    if (index(" \t;&|(){}`", c)) {
      if (c != " " && c != "\t") { at_command = 1; wrapped = 0; on_git = 0 }
      pos++; continue
    }
    w = shell_word(text, pos); pos = word_end
    if (w ~ /^GIT_CONFIG_PARAMETERS=/) {
      m = split(substr(w, length("GIT_CONFIG_PARAMETERS=") + 1), entries, " ")
      for (j = 1; j <= m; j++) {
        gsub("^" q "|" q "$", "", entries[j])
        if (entries[j] != "") note_git_setting(entries[j], 0)
      }
    }
    else if (w ~ /^GIT_CONFIG_KEY_[0-9]+=/)   keys[numbered_env(w, "GIT_CONFIG_KEY_")] = substr(w, index(w, "=") + 1)
    else if (w ~ /^GIT_CONFIG_VALUE_[0-9]+=/) values[numbered_env(w, "GIT_CONFIG_VALUE_")] = substr(w, index(w, "=") + 1)
    else if (at_command && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ;          # another `VAR=value` prefix
    else if (at_command) { w = strip_path(w); on_git = (w == "git"); wrapped = runs_its_arguments(w); at_command = 0 }
    else if (wrapped && strip_path(w) == "git") { on_git = 1; wrapped = 0 }   # `sudo -u root git`, `bash -c git`
    else if (on_git && (prev == "-c" || prev == "--config-env")) note_git_setting(w, prev == "--config-env")
    else if (on_git && w ~ /^--config-env=/) note_git_setting(substr(w, length("--config-env=") + 1), 1)
    prev = w
  }
  for (k in keys) note_git_setting(keys[k] "=" values[k], 0)
}

# Rewrites every `git` invocation into the `git <subcommand> ...` shape the rules
# expect. Git's global options are dropped (`-C dir`, `-c key=val`, `--git-dir=`,
# `--no-pager`, ...; what they set was read by note_git_settings), and a
# subcommand that is an alias is replaced by its expansion: `git p --force` is
# `git push --force` when `alias.p = push`. A `!` alias is a shell command and
# is spliced in as one, without the `git`. The options that take a separate
# value are the ones git.c lists; everything else that starts with `-` is a flag.
function normalise_git(text, keep_words,    tok, n, i, w, out, name, next_name, expansion, head, depth) {
  n = split(text, tok, " ")
  out = ""
  for (i = 1; i <= n; i++) {
    w = tok[i]
    if (w == "") continue
    out = out " " w
    if (w != "git") continue
    for (i++; i <= n; i++) {
      w = tok[i]
      if (w !~ /^-/) break
      if (w ~ /^-(C|c|-git-dir|-work-tree|-namespace|-exec-path|-super-prefix|-config-env|-attr-source)$/) i++
    }
    if (i > n) break
    w = tok[i]
    name = tolower(w)
    if (name in aliases) {
      expansion = aliases[name]
      # An alias may name another alias (git 2.20+); follow it, with a bound in
      # case the user's config loops.
      for (depth = 0; depth < 8 && expansion !~ /^!/; depth++) {
        split(expansion, head, " ")
        next_name = tolower(head[1])
        if (!(next_name in aliases) || next_name == name) break
        name = next_name
        expansion = aliases[name] substr(expansion, length(head[1]) + 1)
      }
      if (expansion ~ /^!/) {
        out = substr(out, 1, length(out) - length(" git"))   # a shell alias replaces `git`
        expansion = substr(expansion, 2)
      }
      w = normalise_tokens(strip_quotes(expansion, keep_words))
      sub(/^ /, "", w); sub(/ $/, "", w)
    }
    out = out " " w
  }
  return out " "
}

# A short-flag cluster carrying one of `letters`, as a rule reads it: `-fu` and
# `-uf` both carry `f`. The trailing space is the word boundary every rule ends
# on, which is what keeps `--signed` from reading as `-d`.
function cluster(letters) {
  return "-[A-Za-z]*[" letters "][A-Za-z]* "
}

# The branch a `git push` in the text lands on when it names no refspec: the
# current one, resolved by the caller into `branch`. `git push`, `git push
# origin`, `git push origin HEAD` and `git push -u origin @` all push the branch
# that is checked out, and no rule can see which one that is from the text alone.
# Approximate by design: the command may cd elsewhere first, and the caller reads
# the project checkout.
function bare_push_lands_on(text,    tok, n, i, w, positional, refspec) {
  n = split(text, tok, " ")
  for (i = 1; i < n; i++) {
    if (tok[i] != "git" || tok[i + 1] != "push") continue
    positional = 0; refspec = ""
    for (i += 2; i <= n; i++) {
      w = tok[i]
      if (w == "" || w ~ /^-/) continue
      if (w ~ /^[;&|(){}`]+$/) break
      if (++positional == 2) refspec = w
    }
    if (positional <= 1 || refspec ~ /^(HEAD|@)$/) return branch
  }
  return ""
}

BEGIN {
  q  = sprintf("%c", 39)   # '
  dq = sprintf("%c", 34)   # "
  quotes = "[" q dq "]"
  placeholder = sprintf("%c", 1)

  # The built-in commands, one per line, as `git --list-cmds=builtins` prints
  # them: an alias may not hide one. Then `alias.p push` per line, as `git config
  # --get-regexp '^alias\.'` prints them; a later line wins, which is git's own
  # precedence. Both handed over through the environment because `awk -v` would
  # read backslashes in an alias as escapes.
  n_cmd = split(ENVIRON["COMMAND_POLICY_GIT_COMMANDS"], cmd_lines, "\n")
  for (i = 1; i <= n_cmd; i++) if (cmd_lines[i] != "") git_commands[cmd_lines[i]]
  n_alias = split(ENVIRON["COMMAND_POLICY_GIT_ALIASES"], alias_lines, "\n")
  for (i = 1; i <= n_alias; i++) {
    if (alias_lines[i] !~ /^alias\.[^ ]+ /) continue
    define_alias(substr(alias_lines[i], 7, index(alias_lines[i], " ") - 7),
                 substr(alias_lines[i], index(alias_lines[i], " ") + 1))
  }
  branch = ENVIRON["COMMAND_POLICY_GIT_BRANCH"]
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
  cmd = unwrap_shell_payloads(cmd)
  note_git_settings(cmd)                                            # quotes still intact here
  cmdq = normalise_git(normalise_tokens(strip_quotes(cmd, 1)), 1)   # quoted words kept
  cmd  = normalise_git(normalise_tokens(strip_quotes(cmd, 0)), 0)   # every quoted string gone
  rawlc = tolower(raw)

  # The git rules below read `git <sub>` args ` <flag> `: args is any run of
  # arguments and a flag is matched as a whole word, so a short flag is found
  # inside a cluster (`-fu` carries `-f`, `-nm` carries `-n`) while a long
  # option is never mistaken for one (`--signed` is not `-d`: the `-` it would
  # have to start from has no space before it).
  args = "( [^;&|]*)? "

  # --- Verification bypass ------------------------------------------------
  deny(" git [^;&|]*--no-verify[ =]", "git --no-verify skips the pre-commit and commit-msg hooks")
  deny(" git commit" args cluster("n"), "git commit -n skips the commit-msg hook")
  if (verdict == "" && hooks_moved) verdict = "git -c core.hooksPath= runs the command with its hooks pointed elsewhere"
  deny(" git config" args "[^ ]*core\\.[Hh]ooks[Pp]ath[= ][^- ]", "moving core.hooksPath disables the pre-commit and commit-msg hooks", cmdq)
  if (verdict == "" && alias_unreadable != "")
    verdict = "an alias defined through --config-env (alias." alias_unreadable ") cannot be read by the policy"

  # --- Discards uncommitted work ------------------------------------------
  deny(" git reset [^;&|]*--hard ",   "git reset --hard discards uncommitted work")
  deny(" git clean ",                 "git clean permanently removes untracked files")
  deny(" git restore ",               "git restore discards working-tree changes")
  # Paths after `checkout` are overwritten from the index or a tree-ish. A `--`
  # anywhere introduces paths; a word that can only be a path (`.`, `./lib`,
  # `../x`, `/abs`) is one without it. `lib/foo.ex` is left alone: it reads the
  # same as a branch named `feature/x`, and refusing those would refuse the
  # branch switch this policy is meant to allow.
  deny(" git checkout" args "(-- |\\.\\.?(/[^ ]*)? |/[^ ]* )", "git checkout <path> discards working-tree changes")
  deny(" git checkout" args "(" cluster("fB") "|--force )", "a forced checkout discards working-tree changes or resets a branch")
  deny(" git switch" args "(" cluster("fC") "|--force |--discard-changes |--force-create )", "a forced switch discards working-tree changes or resets a branch")
  deny(" git stash (drop|clear) ",    "git stash drop/clear destroys stashed work")

  # --- Rewrites history ---------------------------------------------------
  deny(" git rebase ",                "git rebase rewrites history")
  deny(" git commit [^;&|]*--amend ", "git commit --amend rewrites a commit")
  deny(" git (filter-branch|filter-repo) ", "history rewriting is refused")
  deny(" git reflog (expire|delete) ", "expiring or deleting reflog entries removes the recovery path for rewritten history")
  deny(" git gc [^;&|]*--prune[ =]",  "pruning gc can drop unreferenced objects that are still the only copy")
  deny(" git prune ",                 "git prune drops unreferenced objects that may be the only copy")
  deny(" git update-ref ",            "moving or deleting a ref directly can orphan commits")
  deny(" git branch" args "(" cluster("DfMC") "|--force )", "a forced branch delete, move or copy can drop commits")
  deny(" git tag" args "(" cluster("df") "|--delete |--force )", "deleting or moving a tag removes a published marker")

  # --- Irreversible publishing --------------------------------------------
  # Push arguments are refs and flags, never prose, so these run on the copy that
  # keeps quoted words: `git push origin 'HEAD:main'` still names main.
  deny(" git push" args "(--force(-with-lease|-if-includes)?[ =]|" cluster("f") ")", "a force push overwrites published history", cmdq)
  deny(" git push" args "(--delete |--prune |" cluster("d") ")", "git push --delete removes a remote branch", cmdq)
  deny(" git push" args ":[^ ]+ ",  "a colon refspec deletes a remote branch", cmdq)
  deny(" git push" args "\\+[^ ]+ ", "a + refspec is a force push", cmdq)
  deny(" git push" args "--mirror ", "git push --mirror overwrites every remote ref", cmdq)
  deny(" git push" args "([^ ]*[:/])?(main|master) ", "pushing straight to the default branch bypasses review", cmdq)
  if (verdict == "" && bare_push_lands_on(cmdq) ~ /^(main|master)$/)
    verdict = "pushing straight to the default branch bypasses review"
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

# Three things about git only git can answer: which aliases the user has defined
# (an alias stands in for the subcommand every rule keys on), which commands are
# built in (an alias may not hide one), and which branch a bare `git push` lands
# on. Read once, from the project checkout and the user's global config, and
# only when the command mentions git at all. Approximate by design: the command
# may cd elsewhere first, and an alias local to another repository is not seen.
aliases=""
branch=""
commands=""
case "$command" in
  *git*)
    aliases=$(git -C "${CLAUDE_PROJECT_DIR:-.}" config --get-regexp '^alias\.' 2>/dev/null || true)
    branch=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    commands=$(git --list-cmds=builtins 2>/dev/null || true)
    ;;
esac

verdict=$(printf '%s\n' "$command" |
  COMMAND_POLICY_GIT_ALIASES="$aliases" COMMAND_POLICY_GIT_BRANCH="$branch" \
  COMMAND_POLICY_GIT_COMMANDS="$commands" awk "$POLICY")

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
