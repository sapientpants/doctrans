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
# itself -- `-c key=value`, `--config-env`, the GIT_CONFIG_* variables -- and four
# settings are rules in their own right: core.hooksPath moves every hook,
# alias.<name> defines the subcommand the rules key on, a remote's URL sends the
# command somewhere else, and include.path (like GIT_CONFIG_GLOBAL) names a file
# of settings this script never reads. Those are read from the text before the
# quotes come off, because a value with a space in it is quoted.
# A rule that reads a push target runs on a second copy of the text in which a
# quoted word is kept rather than stripped, so `git push origin 'HEAD:main'`
# names the branch it would land on. A rule that reads an argument by its
# position reads that copy without its redirections: in `git push 2>/dev/null
# origin feature` the repository is `origin`.
#
# The remote is one more thing git lets a command decide in several places.
# `git remote set-url` is the obvious one; the same URL is also a setting
# (remote.<name>.url, remote.<name>.pushurl, url.<base>.insteadOf) that `git
# config`, `-c` and the GIT_CONFIG_* variables can write, a line in .git/config,
# and an argument: `git push https://...` needs no remote at all. Each is read
# where it is written.
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
# SQL rule and the heredoc pass so the two lists cannot drift apart. A `docker
# exec` is not one: it runs nothing without a command word, and when that word
# is a client it is named here as well, so counting the exec only read `docker
# exec app sh -c "echo delete from cart"` as SQL.
function names_db_client(text) {
  text = tolower(text)
  return index(text, "psql") || index(text, "dropdb") || index(text, "mysql") || index(text, "sqlite3")
}

# Whether the text carries a statement that destroys data once a client runs
# it. SQL reads any run of whitespace between keywords, so `DROP  TABLE`, a tab
# and a line break are the same statement as `DROP TABLE`, and `TRUNCATE
# documents` needs no `TABLE`. `truncate` is also a coreutils command, which
# takes an option where the SQL takes a name, so only the form followed by a
# name is read as SQL. A `DROP INDEX`, a `DROP CONSTRAINT`, and a `DROP TYPE` or
# `DROP EXTENSION` without `CASCADE` lose no row and are left alone; with
# `CASCADE` the last two take every column of that type with them.
function destructive_sql(text) {
  text = tolower(text)
  return match(text, /drop[ \t\n]+(database|table|schema|owned|column)[ \t\n]|drop[ \t\n]+(extension|type)[^;]*[ \t\n]cascade|truncate[ \t\n]+[a-z_"]|delete[ \t\n]+from[ \t\n]/)
}

# Whether a command in the text hands destructive SQL to a database client. The
# text is split into commands at `;`, `&`, `&&`, `||` and a line break outside
# quotes, so `psql -c "\dt"; truncate dev.log` names a client in one command
# and the coreutils truncate in another. A `|` keeps its two sides together:
# what the left side prints is what the client on the right side runs.
function runs_destructive_sql(text,    i, n, c, open_quote, seg) {
  n = length(text); seg = ""; open_quote = ""
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (open_quote != "") {
      if (c == open_quote) open_quote = ""
      else if (c == "\\" && open_quote == dq) { seg = seg c; c = substr(text, ++i, 1) }
    }
    else if (c == q || c == dq) open_quote = c
    else if (c == "\\") { seg = seg c; c = substr(text, ++i, 1) }
    else if (c == "|" && substr(text, i + 1, 1) == "|") { c = ";"; i++ }
    if (c == ";" || c == "&" || c == "\n") {
      if (open_quote == "" && names_db_client(seg) && destructive_sql(seg)) return 1
      if (open_quote == "") { seg = ""; continue }
    }
    seg = seg c
  }
  return names_db_client(seg) && destructive_sql(seg)
}

# Removes `len` characters of `text` starting at `start`.
function cut(text, start, len) {
  return substr(text, 1, start - 1) substr(text, start + len)
}

# Whether a command word hands its arguments on as another command: `sudo
# /bin/rm` runs rm, `env X=1 git` runs git, and so does a shell whose `-c`
# payload has been unwrapped (`bash -c "/bin/rm -rf build"`) or an eval.
# `docker exec db /usr/bin/dropdb` runs dropdb too, but only through the word
# after its container, which normalise_docker finds.
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

# Whether an option of a word that runs its arguments takes the next word as
# its value, as each command's manual lists them: `sudo -u postgres dropdb`
# runs dropdb, and `postgres` is not the command. An option missing from a
# table is read as a flag, so the word after it is taken for the command.
function wrapper_option_takes_value(wrapper, w) {
  if (index(w, "=")) return 0
  if (wrapper ~ /^(sudo|doas)$/) return w ~ /^(-[A-Za-z]*[CDghpRrTtUu]|--(chdir|chroot|close-from|command-timeout|group|host|other-user|prompt|role|type|user))$/
  if (wrapper == "env")     return w ~ /^(-[A-Za-z]*[CPSu]|--(chdir|split-string|unset))$/
  if (wrapper == "exec")    return w ~ /^-[A-Za-z]*a$/
  if (wrapper == "xargs")   return w ~ /^(-[A-Za-z0-9]*[adEIJLnPRSs]|--(arg-file|delimiter|max-args|max-chars|max-lines|max-procs|process-slot-var))$/
  if (wrapper == "nice")    return w ~ /^(-[A-Za-z]*n|--adjustment)$/
  if (wrapper == "time")    return w ~ /^(-[A-Za-z]*[fo]|--(format|output))$/
  if (wrapper == "timeout") return w ~ /^(-[A-Za-z]*[ks]|--(kill-after|signal))$/
  if (wrapper ~ /sh$/)      return w ~ /^[-+][A-Za-z]*[oO]$/
  return 0
}

# Gives every token a space on each side, which is what the rules match on (see
# the note above the policy). Runs after the quoted strings are gone, so a `;` or
# `(` inside a commit message is not read as a separator. A command's directory
# comes off only where the shell resolves a command: at the start, after a
# separator, after a `VAR=value` prefix, and on the command a word that runs its
# arguments hands them to (`sudo /bin/rm`, `timeout 60 /bin/rm`, `find -exec
# /bin/rm`, the payload of `bash -c`) -- an argument that merely ends in a rule
# word (`cat /tmp/rmdir`) stays a path, and so does one a rule has to read
# whole: the URL in `command git push https://...` and the file in `sudo sed -i
# ... .git/config`. Between such a word and its command sit its own options,
# their values, `VAR=value` settings, a redirection and the duration `timeout`
# takes.
function normalise_tokens(text,    tok, n, i, w, out, expect, wrapper, is_value) {
  while (match(text, /\\[A-Za-z0-9_\/]/))          # `\rm` is `rm` to the shell
    text = cut(text, RSTART, 1)
  gsub(/[;&|(){}`]+/, " & ", text)                 # `;git` -> ` ; git`, `$(rm` -> `$ ( rm`
  n = split(text, tok, /[ \t]+/)
  out = ""; expect = 1; wrapper = ""; is_value = 0
  for (i = 1; i <= n; i++) {
    w = tok[i]
    if (w == "") continue
    if (w ~ /^[;&|(){}`]+$/) { expect = 1; wrapper = "" }
    else if (w ~ /^-(exec|execdir|ok|okdir)$/) expect = 1       # find's command is the next word
    else if (expect && w ~ /^([A-Za-z_][A-Za-z0-9_]*=|-)/) ;    # `X=1 /bin/rm`, `bash -c -x "rm"`: the command is next
    else if (expect) {
      w = strip_path(w); expect = 0; is_value = 0
      wrapper = runs_its_arguments(w) ? w : ""
    }
    else if (wrapper == "") ;                                   # an argument, path and all
    else if (w ~ /^-/) {
      if (wrapper ~ /sh$/ && w ~ /^-[A-Za-z]*c/) expect = 1     # the payload of `bash -c` is a command
      else is_value = wrapper_option_takes_value(wrapper, w)
    }
    else if (w ~ /^[0-9]*[<>]/) is_value = (w ~ /[<>]$/)        # `sudo > log rm`: the file is next
    else if (is_value) is_value = 0
    else if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ;
    else if (wrapper == "timeout" && w ~ /^[0-9.]+[smhd]?$/) ;
    else { w = strip_path(w); wrapper = runs_its_arguments(w) ? w : "" }
    out = out " " w
  }
  return out " "
}

# The text without its redirections, for the rules that read a command's
# arguments by position: `2>/dev/null` and `> push.log` are no argument of the
# command they follow. Runs on normalised text, where `2>&1` has become
# `2> & 1`; that `&` goes too, since it separates nothing.
function drop_redirections(text,    tok, n, i, w, out) {
  n = split(text, tok, " ")
  out = ""
  for (i = 1; i <= n; i++) {
    w = tok[i]
    if (w == "") continue
    if (w ~ /^[0-9]*(>>?|<<?<?)$/) {
      if (tok[i + 1] == "&" && tok[i + 2] ~ /^([0-9]+|-)$/) i += 2
      else if (tok[i + 1] !~ /^[;&|(){}`]+$/) i++
      continue
    }
    if (w ~ /^[0-9]*[<>]/) continue
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

# Whether a configuration key decides where a fetch or a push goes: the URL of
# a remote, its push URL, or a rewrite applied to every URL that starts with
# <base>. Git reads the section and the variable case-insensitively.
function remote_url_key(key) {
  key = tolower(key)
  return key ~ /^remote\..+\.(url|pushurl)$/ || key ~ /^url\..+\.(insteadof|pushinsteadof)$/
}

# Records one configuration setting git would read from the command line or
# the environment. Four are rules: core.hooksPath points the hooks at another
# directory, which is `--no-verify` for every hook at once, alias.<name>
# defines a subcommand, a remote's URL (see remote_url_key) sends the command
# somewhere else, and include.path or includeIf.<condition>.path brings in a
# file of settings this script never reads. Git reads the key
# case-insensitively. With `opaque` the value is the name of an environment
# variable (`--config-env`), which this script cannot read: an alias defined
# that way is refused rather than guessed.
function note_git_setting(setting, opaque,    key, value) {
  key = setting; value = ""
  if (index(setting, "=")) {
    key = substr(setting, 1, index(setting, "=") - 1)
    value = substr(setting, index(setting, "=") + 1)
  }
  key = tolower(key)
  if (key == "core.hookspath") hooks_moved = 1
  else if (remote_url_key(key)) remote_url_set = 1
  else if (key == "include.path" || key ~ /^includeif\..+\.path$/) config_unread = 1
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
# and `grep -c` take their own. GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM replace a
# whole configuration file with one this script never reads, so they are noted
# as well, unless the file is /dev/null and holds nothing. Runs on the text
# before its quotes are stripped, because a value with a space in it is quoted
# and the strip would hide it.
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
    else if (w ~ /^GIT_CONFIG_(GLOBAL|SYSTEM)=/) { if (w !~ /=(\/dev\/null)?$/) config_unread = 1 }
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

# Whether a docker option in `scope` takes the next word as its value, as the
# docker client reads it: `-u postgres` does, `-it` does not, and
# `--user=postgres` carries its own. The tables are the client's own for its
# global options, for `compose`, and for `exec` (`docker <cmd> --help`). The
# `run` table is long, so there every long option is read as taking a value
# except the flags, and a short cluster takes one when its last letter does.
function docker_option_takes_value(scope, w) {
  if (index(w, "=")) return 0
  if (scope == "docker")  return w ~ /^(-c|-H|-l|--config|--context|--host|--log-level|--tlscacert|--tlscert|--tlskey)$/
  if (scope == "compose") return w ~ /^(-f|-p|--file|--project-name|--profile|--env-file|--project-directory|--ansi|--progress|--parallel)$/
  if (scope == "exec")    return w ~ /^(-[A-Za-z]*[euw]|--detach-keys|--env|--env-file|--index|--user|--workdir)$/
  if (scope == "run")     return w ~ /^-[A-Za-z]*[acehlmpuvw]$/ || (w ~ /^--/ && w !~ /^--(build|detach|disable-content-trust|dry-run|help|init|interactive|no-deps|no-healthcheck|no-recreate|no-tty|oom-kill-disable|privileged|publish-all|quiet|quiet-build|quiet-pull|read-only|remove-orphans|rm|service-ports|sig-proxy|tty|use-aliases|use-api-socket)$/)
  return 0
}

# Rewrites every `docker` invocation into the shape the rules and the path
# stripping expect. Docker's global options are dropped, as git's are, so
# `docker --context default volume rm` is `docker volume rm`. An `exec` or a
# `run` (`docker exec`, `docker container run`, `docker compose exec`,
# `docker-compose run`) hands the word after its container or image on as a
# command, so that word loses its directory the way a command word does and,
# when it runs its own arguments (`docker exec db sudo /usr/bin/dropdb`), so do
# they. Every other argument is data and keeps its path: `docker exec db cat
# /srv/rmdir` reads a file, and `docker cp db:/var/lib/rmdir .` copies one.
function normalise_docker(text,    tok, n, i, w, out, scope, want, after_value, strip_all) {
  n = split(text, tok, " ")
  out = ""
  for (i = 1; i <= n; i++) {
    w = tok[i]
    if (w == "") continue
    out = out " " w
    if (w != "docker" && w != "docker-compose") continue
    scope = (w == "docker") ? "docker" : "compose"
    want = "subcommand"; strip_all = 0
    for (i++; i <= n; i++) {
      w = tok[i]
      if (w == "") continue
      if (w ~ /^[;&|(){}`]+$/) { i--; break }
      if (want == "value")     { want = after_value; if (scope != "docker") out = out " " w; continue }
      if (want == "arguments") { out = out " " (strip_all ? strip_path(w) : w); continue }
      if (want == "command")   { w = strip_path(w); strip_all = runs_its_arguments(w); want = "arguments" }
      else if (w ~ /^-/) {
        if (docker_option_takes_value(scope, w)) { after_value = want; want = "value" }
        if (scope == "docker") continue
      }
      else if (want == "container") want = "command"
      else if (scope == "docker" && w == "compose") scope = "compose"
      else if (scope == "docker" && w == "container") ;
      else if (w == "exec" || w == "run") { scope = w; want = "container" }
      else want = "arguments"
      out = out " " w
    }
  }
  return out " "
}

# A short-flag cluster carrying one of `letters`, as a rule reads it: `-fu` and
# `-uf` both carry `f`. The trailing space is the word boundary every rule ends
# on, which is what keeps `--signed` from reading as `-d`.
function cluster(letters) {
  return "-[A-Za-z]*[" letters "][A-Za-z]* "
}

# Whether a `git push` in the text lands on the default branch without naming
# it, which no rule can see from the text alone. Two ways:
#
#   * It pushes the branch that is checked out, which the caller resolves into
#     `branch`: `git push` and `git push origin` name no refspec, and `HEAD`,
#     `@` or a destination the policy cannot read stands for one -- a variable
#     or a command substitution (`git push origin "$(git branch --show-current)"`)
#     reads as `$` or as the placeholder of a quoted string, which no refspec
#     holds. Any refspec of the list counts, not just the first: `git push
#     origin feature HEAD` pushes the current branch too. Only the destination
#     is read: `git push origin "$BRANCH:feature"` lands on feature.
#   * It pushes every branch, main among them, whichever is checked out:
#     `--all`, `--branches`, the `:` that pushes the matching ones, and a glob
#     whose destination can match the default branch (`refs/heads/*`, `*:*`).
#     A glob that cannot (`refs/tags/*`, `refs/heads/feature/*`) passes.
#
# Approximate by design: the command may cd elsewhere first, and the caller
# reads the project checkout. Git refuses `HEAD:` and `@:` as invalid, so they
# push nothing and are not read as the current branch; an empty quoted refspec
# is invalid too, but it reads as the same placeholder as one with a space in
# it, so it is refused with that one.
function push_lands_on_default(text,    tok, n, i, w, dst, positional, current, pushes_all) {
  n = split(text, tok, " ")
  for (i = git_arguments(tok, n, 1, "push"); i; i = git_arguments(tok, n, i, "push")) {
    positional = 0; current = 0; pushes_all = 0
    for (; i <= n; i++) {
      w = tok[i]
      if (push_option_takes_value(w)) { i++; continue }
      if (w ~ /^--(all|branches)$/) pushes_all = 1
      if (w == "" || w ~ /^-/) continue
      if (w ~ /^[;&|(){}`]+$/) break
      if (++positional == 1) continue                       # the repository
      if (w == ":") { pushes_all = 1; continue }
      dst = (index(w, ":") ? substr(w, match(w, /:[^:]*$/) + 1) : w)
      if (w ~ /^(HEAD|@)$/ || dst ~ /\$/ || w == placeholder) current = 1
      else if (glob_matches_default(dst)) pushes_all = 1
    }
    if (pushes_all) return 1
    if ((positional <= 1 || current) && branch ~ ("^" default_branch "$")) return 1
  }
  return 0
}

# Whether a refspec glob can name the default branch, spelled the ways git reads
# a push destination: `main`, `heads/main` or `refs/heads/main`. Git allows one
# `*` per side; with more, the part before the first and after the last are
# matched, which can only match more.
function glob_matches_default(glob,    names, n, k, name, prefix, suffix, spelling) {
  if (!index(glob, "*")) return 0
  prefix = substr(glob, 1, index(glob, "*") - 1)
  suffix = substr(glob, match(glob, /\*[^*]*$/) + 1)
  n = split(default_branches, names, " ")
  for (k = 1; k <= n; k++)
    for (spelling = 1; spelling <= 3; spelling++) {
      name = (spelling == 1 ? "" : spelling == 2 ? "heads/" : "refs/heads/") names[k]
      if (length(name) >= length(prefix) + length(suffix) &&
          substr(name, 1, length(prefix)) == prefix &&
          substr(name, length(name) - length(suffix) + 1) == suffix) return 1
    }
  return 0
}

# Whether a `git push` option takes the next word as its value, so that word is
# neither the repository nor a refspec: in `git push --recurse-submodules check
# origin feature` the repository is `origin`.
function push_option_takes_value(w) {
  return w ~ /^(-o|--push-option|--receive-pack|--exec|--repo|--recurse-submodules)$/
}

# The index in `tok` of the first word after the next `git <subcommand>` at or
# after `from`, 0 when there is none. The rules that read a git command's
# arguments by position start there and stop at the next separator.
function git_arguments(tok, n, from, subcommand,    i) {
  for (i = from; i < n; i++)
    if (tok[i] == "git" && tok[i + 1] == subcommand) return i + 2
  return 0
}

# Whether a `git config` in the text changes where a remote points: it sets or
# unsets one of the keys remote_url_key names, or removes or renames a remote's
# whole section. Reading a key is not a change, and git reads `git config
# <key>` with no value as a read, so `git config remote.origin.url` and `git
# config --get remote.origin.url` pass. Both spellings of the command are read:
# the options (`--unset`, `--remove-section`) and the subcommands git 2.46
# added (`set`, `unset`, `remove-section`).
function config_changes_remote(text,    tok, n, i, w, positional, key, reading, unsetting, on_section, at_subcommand) {
  n = split(text, tok, " ")
  for (i = git_arguments(tok, n, 1, "config"); i; i = git_arguments(tok, n, i, "config")) {
    positional = 0; key = ""; reading = 0; unsetting = 0; on_section = 0; at_subcommand = 1
    for (; i <= n; i++) {
      w = tok[i]
      if (w == "") continue
      if (w ~ /^[;&|(){}`]+$/) break
      if (w ~ /^(-f|--file|--blob|--type|--default|--comment|--value|--url)$/) { i++; continue }
      if (w ~ /^(--get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list)$/) reading = 1
      else if (w ~ /^--unset(-all)?$/) unsetting = 1
      else if (w ~ /^--(remove|rename)-section$/) on_section = 1
      if (w ~ /^-/) continue
      if (at_subcommand) {
        at_subcommand = 0
        if (w ~ /^(get|list)$/) reading = 1
        else if (w == "unset") unsetting = 1
        else if (w ~ /^(remove|rename)-section$/) on_section = 1
        if (w ~ /^(get|list|set|unset|remove-section|rename-section|edit)$/) continue
      }
      if (++positional == 1) key = tolower(w)
    }
    if (reading) continue
    if (on_section && key ~ /^(remote|url)(\.|$)/) return 1
    if (remote_url_key(key) && (positional >= 2 || unsetting)) return 1
  }
  return 0
}

# Whether a `git push` in the text names its repository by something other
# than a remote: a URL, a path, or a variable this script cannot read (`git
# push https://github.com/x/y.git feature`, `git push git@github.com:x/y.git
# feature`, `git push ../mirror feature`, `git push "$URL" feature`). The
# repository is the first argument that is not an option, or the value of
# `--repo`; a remote's name holds no `:`, `/` or `$` and does not start with a
# `.`, and every URL, path and variable does one of the four.
function push_names_no_remote(text,    tok, n, i, w) {
  n = split(text, tok, " ")
  for (i = git_arguments(tok, n, 1, "push"); i; i = git_arguments(tok, n, i, "push")) {
    for (; i <= n; i++) {
      w = tok[i]
      if (w == "") continue
      if (w ~ /^[;&|(){}`]+$/) break
      if (w == "--repo") w = tok[++i]
      else if (push_option_takes_value(w)) { i++; continue }
      else if (w ~ /^--repo=/) w = substr(w, length("--repo=") + 1)
      else if (w ~ /^-/) continue
      if (w ~ /[:\/$]|^\./) return 1
      break
    }
  }
  return 0
}

# The tasks every `mix` in the text runs, as ` task ` words. The first word that
# is not an option is the task -- except after `do`, where a comma on a word or
# a `+` between words starts another task (`mix do ecto.drop, ecto.create`,
# `mix do ecto.create + ecto.drop`). A word after the task is its argument, not a
# task: `mix help ecto.drop` reads the documentation and drops nothing. Runs on
# the copy that keeps quoted words and drops redirections, because `mix
# "ecto.drop"` and `mix 2>/dev/null ecto.drop` are `mix ecto.drop` to mix.
function mix_tasks(text,    tok, n, i, w, task, out, next_is_task, in_do) {
  n = split(text, tok, " ")
  out = ""
  for (i = 1; i <= n; i++) {
    if (tok[i] != "mix") continue
    next_is_task = 1; in_do = 0
    for (i++; i <= n; i++) {
      w = tok[i]
      if (w == "") continue
      if (w ~ /^[;&|(){}`]+$/) break
      if (w == "+") { next_is_task = in_do; continue }
      if (next_is_task && w !~ /^-/) {
        if (w == "do" && !in_do) { in_do = 1; continue }
        task = w; sub(/,$/, "", task)
        out = out " " task
        next_is_task = 0
      }
      if (in_do && w ~ /,$/) next_is_task = 1
    }
  }
  return out " "
}

BEGIN {
  q  = sprintf("%c", 39)   # '
  dq = sprintf("%c", 34)   # "
  quotes = "[" q dq "]"
  placeholder = sprintf("%c", 1)

  # The branches a push must not land on, as words and as the regex the rules
  # build on.
  default_branches = "main master"
  default_branch = default_branches; gsub(/ /, "|", default_branch)
  default_branch = "(" default_branch ")"

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

# Inside a heredoc. The body is data to the shell, so it stays out of `cmd` and
# `raw` -- unless the opening line hands it to a database client: `psql <<SQL`
# runs the body, so it goes to `sql` for the SQL rule, while a body written to a
# file or a commit message is prose whatever it says. The body is also kept
# aside until the terminator arrives. If it never does, this script cannot tell a
# heredoc the shell closes at end of input from an opener it misread, and only one
# of those is safe to skip: END hands the lines back to `cmd` and `raw`.
delim != "" {
  line = $0
  sub(/^[ \t]+/, "", line)          # <<- allows a tab-indented terminator
  if (line == delim) { delim = ""; body = ""; next }
  body = body " " $0
  if (body_runs_sql) sql = sql " " $0
  next
}
{
  delim = heredoc_delim($0)        # the opening line itself is command
  body_runs_sql = (delim != "" && names_db_client($0))
  cmd = cmd " " $0
  raw = raw "\n" $0                # same lines, quotes intact, for the SQL rule
}

END {
  if (delim != "") {                  # an unterminated heredoc hides nothing
    cmd = cmd body
    if (!body_runs_sql) raw = raw body
  }
  cmd = unwrap_shell_payloads(cmd)
  note_git_settings(cmd)                                            # quotes still intact here
  cmdq = normalise_git(normalise_docker(normalise_tokens(strip_quotes(cmd, 1))), 1)   # quoted words kept
  cmd  = normalise_git(normalise_docker(normalise_tokens(strip_quotes(cmd, 0))), 0)   # every quoted string gone
  cmdq_args = drop_redirections(cmdq)                               # for the rules that read by position

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
  if (verdict == "" && config_unread)
    verdict = "GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM or include.path hands git a configuration file the policy cannot read"
  deny(" git config(( -[^ ]+)* edit|" args "(-e|--edit)) ", "git config --edit changes the configuration in an editor, where the policy cannot read it")

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
  deny(" git push" args "([^ ]*[:/])?" default_branch " ", "pushing straight to the default branch bypasses review", cmdq)
  if (verdict == "" && push_lands_on_default(cmdq_args))
    verdict = "pushing straight to the default branch bypasses review"
  deny(" gh api [^;&|]*(-X|--method)[ =]DELETE ", "a DELETE through the GitHub API is irreversible")
  deny(" gh release (delete|delete-asset|edit|upload) ", "mutating a published release is irreversible")

  # --- Remote configuration (AGENTS.md: never change the remote URL) ------
  # The URL is read wherever git would take it from: the `remote` subcommand
  # (behind its own options: `git remote -v add`), a `-c` or GIT_CONFIG_*
  # setting, `git config`, the config file itself, and the push that names a
  # URL and so needs no remote. Keys, URLs and paths are never prose, so the
  # last three read the copy that keeps quoted words. The config file is
  # written by an in-place edit, by a redirection, by `tee` and `dd`, and as
  # the destination of a copy; `mv` takes it away wherever it stands.
  deny(" git remote( -[^ ]+)* (set-url|add|remove|rename|rm) ", "changing the git remote is forbidden by AGENTS.md")
  if (verdict == "" && remote_url_set)
    verdict = "a remote URL set through -c or GIT_CONFIG_* changes the git remote for the command, which AGENTS.md forbids"
  if (verdict == "" && config_changes_remote(cmdq_args))
    verdict = "changing a remote URL through git config is forbidden by AGENTS.md"
  deny(" (g?sed|perl)" args "(-[A-Za-z]*i[^ ]*|--in-place[^ ]*) ([^;&|]* )?[^ ;&|]*\\.git/config ", "editing .git/config directly can change the git remote, which AGENTS.md forbids", cmdq)
  deny("( tee" args "|>>? ?| dd" args "of=)[^ ;&|]*\\.git/config ", "writing to .git/config directly can change the git remote, which AGENTS.md forbids", cmdq)
  deny(" (cp|ln|install|rsync)" args "[^ ;&|]*\\.git/config ($|[;&|])", "replacing .git/config directly can change the git remote, which AGENTS.md forbids", cmdq_args)
  deny(" mv" args "[^ ;&|]*\\.git/config ", "moving .git/config directly can change the git remote, which AGENTS.md forbids", cmdq_args)
  if (verdict == "" && push_names_no_remote(cmdq_args))
    verdict = "pushing to a URL, a path or a variable is a one-off remote, which AGENTS.md forbids; push to a configured remote by name"
  deny(" git branch [^;&|]*(--set-upstream-to|-u) ", "changing a branch upstream rewires where work is pushed")

  # --- Recursive deletion -------------------------------------------------
  deny(" rm [^;&|]*(-[A-Za-z]*[rR][A-Za-z]*|--recursive) ", "recursive deletion with rm is refused")
  deny(" rmdir ",                     "rmdir is refused")
  deny(" [Rr]emove-[Ii]tem [^;&|]*(-[Rr]ecurse|-r) ", "recursive PowerShell deletion is refused")
  deny(" sudo rm ",                   "deleting as root is refused")

  # --- This project's data ------------------------------------------------
  # A mix task is read from wherever mix would run it: `mix do ecto.drop,
  # ecto.create` and `mix "ecto.drop"` drop the database as surely as `mix
  # ecto.drop`. A rollback drops every table the migrations it undoes created.
  tasks = mix_tasks(cmdq_args)
  deny(" ecto\\.(drop|reset) ",       "dropping the database destroys local data", tasks)
  deny(" ecto\\.rollback ",           "rolling back migrations drops the tables they created, with their data", tasks)
  deny(" mix deps\\.clean [^;&|]*--all ", "AGENTS.md: deps.clean --all is almost never needed")
  deny(" docker(-| )compose [^;&|]*down [^;&|]*(-v|--volumes) ", "compose down -v deletes the pgdata volume")
  deny(" docker (volume (rm|remove|prune)|system prune) ", "removing docker volumes destroys the database")
  deny(" dropdb ",                    "dropping the database destroys local data")

  # Destructive SQL reaches the client as a quoted argument or a heredoc body, so
  # it is gone from cmd by now -- match the raw text instead. A heredoc body
  # handed to a client is SQL by construction; on the command lines, requiring a
  # database client in the same command keeps prose that merely says "drop
  # table" from tripping this.
  if (verdict == "" && (destructive_sql(sql) || runs_destructive_sql(raw)))
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
