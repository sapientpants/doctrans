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
  git init -q -b "$2" "$1" || return 1
  git -C "$1" -c user.email=policy@test -c user.name=policy -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q --allow-empty -m init || return 1
}
mk_repo "$scratch/on-main" main || exit 1
mk_repo "$scratch/on-feature" feature || exit 1

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
# A separator glued to the next word is still a separator.
block|true;git reset --hard
block|cd sub;git clean -fd
block|x=1;git rebase main
block|true&&rm -rf build
block|false||rm -rf build
block|echo x|rm -rf build
block|(rm -rf build)
block|$(rm -rf build)
block|`rm -rf build`
block|{ rm -rf build; }
block|git push -f;echo done
# A path or a backslash on the command word does not rename it.
block|/bin/rm -rf build
block|/usr/bin/git push --force
block|./rm -rf build
block|../bin/rm -rf build
block|bin/git reset --hard
block|~/bin/rm -rf build
block|$HOME/bin/git push --force
block|X=1 /bin/rm -rf build
block|\rm -rf build
block|\git reset --hard
# A word that runs its arguments hands the path on to the shell.
block|sudo /bin/rm -rf build
block|sudo -u root /bin/rm -rf build
block|env /bin/rm -rf build
block|xargs -0 /bin/rm -rf < list
block|find . -name '*.tmp' -exec /bin/rm -rf {} \;
block|nohup /usr/bin/git push --force &
# A quoted payload handed to a shell is a command, not data.
block|bash -c "rm -rf build"
block|sh -c 'git push --force'
block|zsh -lc "cd x;rm -rf y"
block|dash -c "rm -rf build"
block|ksh -c "git clean -fd"
block|/bin/bash -c "git reset --hard"
block|./bash -c "git reset --hard"
block|eval "git reset --hard"
block|true && bash -c 'rm -rf build'
block|bash -cx "rm -rf build"
block|bash -ce "rm -rf build"
block|bash -x -c "git reset --hard"
block|bash -c -x "rm -rf build"
block|bash -c -- "rm -rf build"
block|bash -c $'rm -rf build'
block|bash -c "r""m -rf build"
block|bash -c rm" -rf build"
block|sh -c "rm -rf 'build'"
block|bash -c "echo start; rm -rf build"
# Git's global options sit between `git` and the subcommand the rules key on.
block|git -C . reset --hard
block|git -C /tmp/x clean -fd
block|git -C . push --force origin feature
block|git --git-dir=.git --work-tree=. reset --hard
block|git --no-pager rebase main
block|git -c user.name=x commit --amend
block|git -c "user.name=x y" commit --amend
block|git -c 'core.hooksPath=/dev/null' commit -m x
block|git -c core.hooksPath=/dev/null commit -m x
block|git -c CORE.HooksPath=/dev/null commit -m x
block|git --config-env=core.hooksPath=HOOKS commit -m x
block|git config core.hooksPath /dev/null
block|git config --global core.hooksPath=/dev/null
# A short flag keeps its meaning inside a cluster.
block|git push -fu origin feature
block|git push -uf origin feature
block|git push -d origin feature
block|git commit -nm x
block|git commit -anm x
block|git branch -fd feature
block|git branch -Df feature
block|git tag -df v1.0.0
block|git checkout -fb feature
# Synonyms and spellings of the refused operations.
block|git branch --force --delete feature
block|git branch --delete --force feature
block|git branch -f main HEAD~5
block|git branch --force main HEAD~5
block|git branch -M main
block|git branch -C old new
block|git checkout -B feature origin/main
block|git switch -C feature
block|git switch --force-create feature
block|git tag --delete v1.0.0
block|git tag -f v1.0.0
block|git push origin --delete feature
block|git push --prune origin
block|git push origin +feature
block|git push origin +HEAD:feature
block|git push --force-with-lease=feature:abc origin feature
block|git push --force-if-includes --force-with-lease origin feature
block|git reflog delete HEAD@{1}
block|git prune --expire=now
block|git update-ref refs/heads/main HEAD~5
block|git update-ref -d refs/heads/feature
block|git checkout HEAD -- lib/foo.ex
block|git checkout main -- .
block|git checkout ./lib
block|git checkout ../lib/foo.ex
block|git checkout /abs/path
block|git checkout -q -- lib
# A quoted push target is still the ref it names.
block|git push origin 'HEAD:main'
block|git push origin "main"
block|git push origin HEAD:refs/heads/main
block|git push origin main:main
block|git push origin feature:master
block|git push origin ':feature'
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
allow|rm /tmp/stale.log
allow|ls /usr/local/bin
allow|cat /tmp/rmdir
allow|ls /opt/mkfs-tools
allow|cat /var/log/dropdb
allow|cp notes.md ~/bin/git-notes
allow|git --git-dir=/tmp/rm status
allow|cat /etc/hosts | grep local
allow|find . -name '*.log' -exec rm {} \;
allow|echo "(rm -rf build)" >> notes.md
allow|git commit -m "fix(x): bash -c 'rm -rf build' is refused"
allow|bash -c "mix test"
allow|bash -c 'echo "rm -rf build is refused"'
allow|bash -cx "mix test"
allow|bash -c $'mix test'
allow|bash -c "mix "'test'
allow|bash -c "echo "'"rm -rf build"'
allow|bash script.sh -c "rm -rf build"
allow|mix test 2>&1 | tail -5
allow|git log --format=%s%n%b
# A long option is never read as the short flag its letters contain.
allow|git push --signed origin feature
allow|git push --follow-tags origin feature
allow|git push --dry-run origin feature
allow|git push --set-upstream origin feature
allow|git commit --only -m x lib/a.ex
allow|git commit --branch -m x
allow|git commit --no-edit -m x
allow|git tag --format=%(refname) --list
allow|git branch --format=%(refname) --list
allow|git branch -d feature
allow|git branch -m old new
allow|git branch -c old new
allow|git branch -vv
allow|git tag -a v1.0.0 -m "release"
allow|git tag -l
# A branch may look like a path; only a word that can be nothing else is one.
allow|git checkout feature/x
allow|git checkout -b feature origin/main
allow|git checkout -b feature/x --track origin/feature/x
allow|git checkout -q main
allow|git switch feature/x
allow|git switch -c feature/x
# Global options on a harmless subcommand stay harmless.
allow|git -C . status
allow|git -C /tmp/x log --oneline -5
allow|git -c user.name=x commit -m x
allow|git -c 'user.name=x y' commit -m x
allow|git --no-pager diff
allow|git -c core.pager=cat log -1
allow|git config user.name x
allow|git config --get core.hooksPath
# Push targets that merely contain the default branch's name.
allow|git push origin feature-main
allow|git push origin maintenance
allow|git push origin main-fix
allow|git push origin HEAD:feature/main-fix
allow|git push origin origin/main:feature
# Prose still is not a command.
allow|git commit -m "git push origin main is refused"
allow|git commit -m "the policy refuses -c core.hooksPath"
allow|git log --grep='rebase' --oneline
allow|grep -rn "rm" lib
allow|grep 'rm' -r lib
CASES

echo
echo "layer 2: a bare push resolves the branch it would land on"
report block "$(shell_policy_in "$scratch/on-main" 'git push')" 'bare push, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git push origin')" 'push naming only a remote, repo on main'
report allow "$(shell_policy_in "$scratch/on-feature" 'git push')" 'bare push, repo on a feature branch'
report allow "$(shell_policy_in "$scratch/on-feature" 'git push origin')" 'push naming only a remote, repo on a feature branch'
report allow "$(shell_policy_in "$scratch/on-main" 'git push origin some-feature')" 'explicit feature target, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git push origin HEAD')" 'push of HEAD, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git push -u origin @')" 'push of @, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git -C . push')" 'bare push behind a global option, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git --no-pager push origin')" 'push naming only a remote behind a global option, repo on main'
report allow "$(shell_policy_in "$scratch/on-feature" 'git push origin HEAD')" 'push of HEAD, repo on a feature branch'

# A git alias stands in for the subcommand, so it is resolved from the checkout's
# config before the rules run. These aliases are defined in the scratch repositories
# only; a developer's own global aliases cannot make a case pass or fail.
echo
echo "layer 2: a git alias is the subcommand it expands to"
for repo in on-main on-feature; do
  git -C "$scratch/$repo" config alias.p push
  git -C "$scratch/$repo" config alias.c 'commit -am'
  git -C "$scratch/$repo" config alias.pf 'push --force'
  git -C "$scratch/$repo" config alias.pp 'p -u'
  git -C "$scratch/$repo" config alias.nuke '!rm -rf build'
  git -C "$scratch/$repo" config alias.lg "log --graph --pretty=format:'%h %s'"
  git -C "$scratch/$repo" config alias.loop1 loop2
  git -C "$scratch/$repo" config alias.loop2 loop1
done
report block "$(shell_policy_in "$scratch/on-feature" 'git p --force origin feature')" 'git p --force (alias.p = push)'
report block "$(shell_policy_in "$scratch/on-feature" 'git p -f origin feature')" 'git p -f'
report block "$(shell_policy_in "$scratch/on-feature" 'git p origin main')" 'git p origin main'
report block "$(shell_policy_in "$scratch/on-main" 'git p')" 'bare git p, repo on main'
report block "$(shell_policy_in "$scratch/on-main" 'git p origin')" 'git p origin, repo on main'
report block "$(shell_policy_in "$scratch/on-feature" 'git c -n -m x')" 'git c -n (alias.c = commit -am)'
report block "$(shell_policy_in "$scratch/on-feature" 'git c --amend')" 'git c --amend'
report block "$(shell_policy_in "$scratch/on-feature" 'git -C . c --amend')" 'alias behind a global option'
report block "$(shell_policy_in "$scratch/on-feature" 'git pf origin feature')" 'git pf (alias.pf = push --force)'
report block "$(shell_policy_in "$scratch/on-feature" 'git pp origin main')" 'git pp origin main (alias.pp = p -u, nested)'
report block "$(shell_policy_in "$scratch/on-feature" 'git nuke')" 'git nuke (alias.nuke = !rm -rf build)'
report block "$(shell_policy_in "$scratch/on-feature" '/usr/bin/git p --force')" 'alias through a path on the command'
report allow "$(shell_policy_in "$scratch/on-feature" 'git p origin feature')" 'git p origin feature'
report allow "$(shell_policy_in "$scratch/on-feature" 'git c -m x')" 'git c -m x'
report allow "$(shell_policy_in "$scratch/on-feature" 'git lg -5')" 'git lg (alias with a quoted format)'
report allow "$(shell_policy_in "$scratch/on-feature" 'git loop1')" 'an alias cycle resolves without hanging'
report allow "$(shell_policy_in "$scratch/on-feature" 'git undefined-alias --force')" 'a word that is no alias is left alone'

echo
echo "layer 2: data must not be mistaken for commands"
report block "$(shell_policy 'psql -c "DROP TABLE documents"')" 'psql -c "DROP TABLE documents"'
report allow "$(shell_policy 'git commit -m "feat(db): drop table legacy_pages in a migration"')" 'commit message naming DROP TABLE'
report allow "$(shell_policy 'echo "never run rm -rf /" >> notes.md')" 'quoted prose naming rm -rf'
report allow "$(shell_policy "$(printf 'git commit -F - <<%sEOF%s\nwhy rm -rf and git push --force are refused\nEOF' "'" "'")")" 'heredoc commit message naming the rules'

# Multi-line commands, written with $'...' so the newlines and quotes are literal.
# A `<<` the shell would not read as a heredoc opener must not swallow the lines
# after it, and a real body is still data -- except to the database client it is
# being fed to.
echo
echo "layer 2: a heredoc is recognised only where the shell would see one"
report block "$(shell_policy $'echo <<<x\nrm -rf build')" 'a here-string opens no heredoc'
report block "$(shell_policy $'echo \'<<EOF\'\nrm -rf build')" 'a single-quoted << opens no heredoc'
report block "$(shell_policy $'echo "a <<EOF b"\nsudo rm -rf /')" 'a double-quoted << opens no heredoc'
report block "$(shell_policy $'# note <<EOF\ngit reset --hard')" 'a << inside a comment opens no heredoc'
report block "$(shell_policy $'cat <<EOF\nnever closed\nrm -rf build')" 'an unterminated heredoc hides nothing'
report block "$(shell_policy $'cat <<EOF\nnever closed\npsql -c "DROP TABLE documents"')" 'an unterminated heredoc hides no SQL either'
report block "$(shell_policy $'cat <<EOF\nrm -rf build\nEOF\nrm -rf build')" 'the command after a heredoc is still inspected'
report block "$(shell_policy $'psql doctrans_dev <<SQL\nDROP TABLE documents;\nSQL')" 'destructive SQL fed through a heredoc'
report block "$(shell_policy $'docker exec -i db psql -U doctrans <<-SQL\n\tTRUNCATE TABLE documents;\n\tSQL')" 'destructive SQL fed through a <<- heredoc'
report allow "$(shell_policy $'cat <<EOF\nrm -rf build\nEOF')" 'heredoc body naming rm -rf'
report allow "$(shell_policy $'cat <<"EOF" > notes.md\nnever run git reset --hard\nEOF')" 'quoted-delimiter heredoc body naming the rules'
report allow "$(shell_policy $'psql doctrans_dev <<SQL\nSELECT count(*) FROM documents;\nSQL')" 'harmless SQL fed through a heredoc'
report allow "$(shell_policy $'cat <<EOF > notes.md\npsql: never drop table by hand\nEOF')" 'heredoc written to a file naming psql and DROP TABLE'
report allow "$(shell_policy $'git commit -F - <<EOF\nfix(db): psql no longer runs drop table\nEOF')" 'heredoc commit message naming psql and DROP TABLE'
report allow "$(shell_policy 'grep <<<"rm -rf build" notes.md')" 'here-string holding rm -rf'

echo
if ! command -v node >/dev/null 2>&1; then
  echo "layer 3: skipped (node is absent)"
elif [ ! -f "$repo_root/scripts/fixtures/type-strip-probe.ts" ]; then
  report pass fail 'TypeScript capability probe is missing'
elif ! node "$repo_root/scripts/fixtures/type-strip-probe.ts" >/dev/null 2>&1; then
  echo "layer 3: skipped (node cannot execute the known-good TypeScript probe)"
else
  echo "layer 3: pi extension adapter"
  if node --test "$repo_root/scripts/pi-adapter.test.mjs"; then
    report pass pass 'pi adapter and harness failure cases'
  else
    report pass fail 'pi adapter and harness failure cases (see diagnostics above)'
  fi
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
