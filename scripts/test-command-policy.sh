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
#
# The developer's own git config is pinned away for the same reason: the policy
# reads aliases from the global config too, so without this a `~/.gitconfig` alias
# named like a case's subcommand would decide that case. The one section that
# tests the global config hands the policy a file of its own.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
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

# The policy's verdict on a command. Environment the policy reads is set on the
# call (`CLAUDE_PROJECT_DIR=... shell_policy ...`), which bash exports to the
# function's commands for that call only.
shell_policy() { # command -> block|allow
  printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | "$policy" >/dev/null 2>&1
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
# A mix task is read wherever mix would run it (#278).
block|mix do ecto.drop
block|mix do ecto.drop, ecto.create
block|mix do ecto.create, ecto.drop
block|mix do ecto.create + ecto.drop
block|mix do ecto.drop --quiet, ecto.create
block|mix do "ecto.reset"
block|mix "ecto.drop"
block|mix ecto.drop --force
block|MIX_ENV=test mix ecto.drop
block|bash -c "mix do ecto.drop"
block|mix ecto.rollback
block|mix ecto.rollback --all
block|mix do ecto.rollback --to 0, ecto.migrate
block|docker volume remove doctrans_pgdata
block|dropdb doctrans_dev
block|/usr/bin/dropdb doctrans_dev
block|sudo -u postgres dropdb doctrans_dev
block|docker exec db dropdb doctrans_dev
block|docker exec -it db /usr/bin/dropdb doctrans_dev
block|docker exec db bash -c "dropdb doctrans_dev"
# A docker exec or run hands the word after its container on as a command, and
# a global option sits between docker and its subcommand (#278).
block|docker compose exec db /usr/bin/dropdb doctrans_dev
block|docker compose -f docker-compose.yml exec -u postgres db /usr/bin/dropdb doctrans_dev
block|docker-compose exec db /usr/bin/dropdb doctrans_dev
block|docker exec -itu postgres db /usr/bin/dropdb doctrans_dev
block|docker container exec db /usr/bin/dropdb doctrans_dev
block|docker run --rm -e PGHOST=db postgres:16 /usr/bin/dropdb doctrans_dev
block|docker exec db sudo -u postgres /usr/bin/dropdb doctrans_dev
block|docker exec db bash -c "/usr/bin/dropdb doctrans_dev"
block|docker exec db /bin/rm -rf /var/lib/postgresql/data
block|docker exec db /usr/bin/git push --force origin feature
block|docker exec db ls; rm -rf build
block|docker --context default volume rm doctrans_pgdata
block|docker -H unix:///var/run/docker.sock volume remove doctrans_pgdata
block|docker -D volume prune -f
block|docker compose -f docker-compose.yml down -v
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
block|bash -c "/bin/rm -rf build"
block|bash -c "sudo /bin/rm -rf build"
block|eval "/usr/bin/git reset --hard"
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
block|git --config-env core.hooksPath=HOOKS commit -m x
block|git config core.hooksPath /dev/null
block|git config --global core.hooksPath=/dev/null
block|sudo -u root git -c core.hooksPath=/x commit -m x
block|bash -c "git -c core.hooksPath=/x commit -m x"
# Git reads its configuration from the environment as well as from `-c`.
block|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x
block|GIT_CONFIG_PARAMETERS="'core.hooksPath=/dev/null'" git commit -m x
block|export GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null'; git commit -m x
block|env GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git commit -m x
# An alias defined on the command line is an alias like any other -- and one
# that would hide a built-in command is ignored, as git ignores it.
block|git -c alias.qq=push qq --force origin feature
block|git -c 'alias.qq=push --force' qq origin feature
block|git -c alias.qq='push --force' qq origin feature
block|git -c "alias.qq=!rm -rf build" qq
block|git -c ALIAS.QQ=push QQ --force origin feature
block|GIT_CONFIG_KEY_0=alias.qq GIT_CONFIG_VALUE_0='push --force' git qq origin feature
block|git --config-env=alias.qq=QQ qq origin feature
block|git -c alias.push=status push --force origin feature
block|git -c alias.rm=status -c alias.push=status push --force origin feature
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
block|git gc --prune=now
block|git gc --prune
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
# The remote is changed wherever git reads its URL from, not only through
# `git remote` (#279).
block|git -C . remote set-url origin git@github.com:x/y.git
block|git remote -v add fork https://github.com/x/y.git
block|git remote rm origin
block|git config remote.origin.url https://github.com/x/y.git
block|git config --local remote.origin.pushurl https://github.com/x/y.git
block|git config --global url.https://github.com/.insteadOf git@github.com:
block|git config url."https://github.com/".pushInsteadOf "git@github.com:"
block|git config set remote.origin.url https://github.com/x/y.git
block|git config --add remote.origin.url https://github.com/x/y.git
block|git config --replace-all remote.origin.url https://github.com/x/y.git
block|git config -f .git/config remote.origin.url https://github.com/x/y.git
block|git config REMOTE.origin.URL https://github.com/x/y.git
block|git config 'remote.origin.url' 'https://github.com/x/y.git'
block|git config --unset remote.origin.url
block|git config unset remote.origin.pushurl
block|git config --remove-section remote.origin
block|git config rename-section remote.origin remote.upstream
block|git -C . config remote.origin.url https://github.com/x/y.git
block|git status && git config remote.origin.url https://github.com/x/y.git
block|git -c remote.origin.url=https://github.com/x/y.git push origin feature
block|git -c remote.origin.pushurl=https://github.com/x/y.git push origin feature
block|git -c 'url.https://github.com/.insteadOf=git@github.com:' fetch origin
block|git --config-env=remote.origin.url=NEW_URL push origin feature
block|GIT_CONFIG_PARAMETERS="'remote.origin.url=https://github.com/x/y.git'" git push origin feature
block|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=https://github.com/x/y.git git push origin feature
block|git push https://github.com/x/y.git feature
block|git push git@github.com:x/y.git feature
block|git push ssh://git@github.com/x/y.git feature
block|git push -u 'https://github.com/x/y.git' feature
block|git push "git@github.com:x/y.git" feature
block|git push -o ci.skip https://github.com/x/y.git feature
block|git push --repo=https://github.com/x/y.git
block|git push --repo https://github.com/x/y.git
block|git push ../mirror feature
block|git push /tmp/mirror.git feature
block|git -C . push https://github.com/x/y.git feature
block|sed -i '' 's#git@github.com:#https://github.com/#' .git/config
block|sed -i.bak s/a/b/ .git/config
block|perl -pi -e 's/a/b/' .git/config
block|echo '[remote "fork"]' >> .git/config
block|printf x | tee -a .git/config
block|git config --unset-all remote.origin.url
block|git config --rename-section remote.origin remote.upstream
block|gsed -i s/a/b/ .git/config
block|cp /tmp/config .git/config
block|cp /tmp/config .git/config 2>/dev/null
block|mv .git/config /tmp/config
block|dd if=/tmp/config of=.git/config
block|git config --edit
block|git config edit
# A word that runs its arguments hands them on as they are, so the URL and the
# file are still whole when the rule reads them -- and the command behind an
# option, a value or a duration is still found.
block|command git push https://github.com/x/y.git feature
block|env git push git@github.com:x/y.git feature
block|timeout 60 git push https://github.com/x/y.git feature
block|sudo -n git push https://github.com/x/y.git feature
block|bash -c "git push https://github.com/x/y.git feature"
block|command git push ../mirror feature
block|command sed -i 's/a/b/' .git/config
block|sudo -n sed -i s/a/b/ .git/config
block|bash -c "echo x >> .git/config"
block|bash -c "tee .git/config"
block|timeout 60 /bin/rm -rf build
block|timeout -k 5 1m /bin/rm -rf build
block|sudo -n /bin/rm -rf build
block|sudo -u git /bin/rm -rf build
block|sudo > /dev/null /bin/rm -rf build
block|nice -n 5 /bin/rm -rf build
block|nohup nice /usr/bin/git push --force
# A redirection is no argument: it neither hides the one after it nor counts
# as one.
block|git push 2>/dev/null https://github.com/x/y.git feature
block|git push --recurse-submodules check https://github.com/x/y.git feature
block|git config remote.origin.url https://github.com/x/y.git 2>&1
block|mix 2>/dev/null ecto.drop
# A repository the policy cannot read is not a remote it can vouch for, and
# neither is a configuration file it never opens.
block|git push $URL feature
block|git push "$URL" feature
block|GIT_CONFIG_GLOBAL=/tmp/other.gitconfig git push origin feature
block|export GIT_CONFIG_SYSTEM=/tmp/other.gitconfig
block|git -c include.path=/tmp/other.gitconfig push origin feature
block|git -c includeIf.gitdir:/x/.path=/tmp/other.gitconfig push origin feature
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
allow|mix help ecto.drop
allow|mix help ecto.rollback
allow|mix ecto.migrate
allow|mix ecto.migrate --to 0
allow|mix ecto.dump
allow|mix do ecto.create, ecto.migrate
allow|mix do deps.get + compile
allow|echo "mix ecto.drop is refused" >> notes.md
allow|docker compose up -d db
allow|docker compose down
allow|docker compose rm -sfv db
allow|docker volume ls
allow|docker volume inspect doctrans_pgdata
allow|docker exec db cat /var/log/postgresql.log
# Every other docker argument is data and keeps its path.
allow|docker exec db cat /srv/rmdir
allow|docker compose exec db tail -f /var/log/rm -r
allow|docker cp db:/var/lib/rmdir ./x
allow|docker logs db | grep /opt/rmdir
allow|docker run --rm -v ./rmdir:/x img ls
allow|docker exec db ls; cat /srv/rmdir
allow|docker exec app grep -r "delete from" src
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
# Reading where the remote points changes nothing.
allow|git remote -v
allow|git remote get-url origin
allow|git remote show origin
allow|git config remote.origin.url
allow|git config --get remote.origin.url
allow|git config get remote.origin.url
allow|git config --get-regexp '^remote\.'
allow|git config --list
allow|git config remote.origin.url > /tmp/url.txt
allow|git config remote.origin.url && git status
allow|git config branch.feature.remote origin
allow|git config remote.origin.prune true
allow|git -c remote.origin.prune=true fetch origin
allow|git push -o ci.skip origin feature
allow|git push --push-option ci.variable=URL=https://x/y origin feature
allow|git push origin feature/x
allow|git push origin HEAD:feature/x
allow|git fetch https://github.com/x/y.git feature
allow|cat .git/config
allow|sed -n p .git/config
allow|grep url .git/config > /tmp/url.txt
allow|git commit -m "docs: git config remote.origin.url https://x/y is refused"
allow|git commit -m "docs: git push https://github.com/x/y.git is refused"
allow|git config remote.origin.url 2>&1
allow|git config remote.origin.url 2>/dev/null
allow|git config --get remote.origin.url 2>&1
allow|git push -u 2>/dev/null origin feature
allow|git push --recurse-submodules check origin feature
allow|git push origin feature >/tmp/push.log 2>&1
allow|git push origin feature 2>&1 | tail -5
allow|command git push origin feature
allow|timeout 60 git push origin feature
allow|sudo -u postgres cat /srv/rmdir
allow|GIT_CONFIG_GLOBAL=/dev/null git status
allow|cp .git/config /tmp/config.bak
allow|git config user.name edit
allow|git -c alias.st=status st
allow|git -c alias.st='status -s' st
allow|git -c alias.qq=push qq origin feature
allow|GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x git commit -m x
allow|GIT_CONFIG_PARAMETERS="'user.name=x'" git commit -m x
allow|git commit -c HEAD~1 -m x
allow|git gc
allow|git gc --auto
# Another command's `-c` is not git's.
allow|grep -c core.hooksPath=foo lib
allow|psql -c 'alias.x=y'
allow|bash -c "alias.x=y"
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
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push')" 'bare push, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin')" 'push naming only a remote, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push')" 'bare push, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin')" 'push naming only a remote, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin some-feature')" 'explicit feature target, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin HEAD')" 'push of HEAD, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push -u origin @')" 'push of @, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git -C . push')" 'bare push behind a global option, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git --no-pager push origin')" 'push naming only a remote behind a global option, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin HEAD')" 'push of HEAD, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push 2>/dev/null')" 'bare push with a redirection, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push >/tmp/push.log 2>&1')" 'bare push with two redirections, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin 2>/dev/null')" 'a redirection is not a refspec, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push --set-upstream origin HEAD')" 'push of HEAD with --set-upstream, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy "git push origin 'HEAD'")" 'push of a quoted HEAD, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git -C . push origin main')" 'push to main behind a global option'
# HEAD may be any refspec of the list, not just the first.
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin feature HEAD')" 'push of HEAD as a later refspec, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin feature @')" 'push of @ as a later refspec, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin feature HEAD')" 'push of HEAD as a later refspec, repo on a feature branch'
# A refspec the policy cannot read stands for the current branch.
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin "$BRANCH"')" 'push of a variable, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin $(git branch --show-current)')" 'push of a command substitution, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin "$(git branch --show-current)"')" 'push of a quoted command substitution, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin "$BRANCH"')" 'push of a variable, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push -u origin "$(git branch --show-current)"')" 'push of a command substitution, repo on a feature branch'
# Git refuses these as invalid refspecs, so they push nothing.
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin HEAD:feature')" 'HEAD to a named feature branch, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin HEAD:HEAD')" 'HEAD:HEAD creates a branch named HEAD, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin HEAD:')" 'HEAD with an empty destination, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin @:')" '@ with an empty destination, repo on main'
# Only the destination of a refspec is read for the current branch.
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin "$BRANCH:feature"')" 'a variable source to a named feature branch, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git push origin "feature:$BRANCH"')" 'a named source to a variable destination, repo on main'
# Pushing every branch lands on main whichever is checked out.
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push --all origin')" 'push --all, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin --branches')" 'push --branches, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin :')" 'push of the matching branches, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin 'refs/heads/*'")" 'push of a glob refspec, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin '*:*'")" 'push of a glob pair, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin 'refs/heads/feature/*:refs/heads/m*'")" 'a glob destination that matches main, repo on a feature branch'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin 'refs/heads/*:heads/*'")" 'a short glob destination that matches main, repo on a feature branch'
# A glob whose destination cannot name the default branch lands elsewhere.
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin 'refs/tags/*:refs/tags/*'")" 'push of a tag glob, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin "refs/tags/v1*"')" 'push of a tag prefix glob, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy "git push origin 'refs/heads/feature/*:refs/heads/feature/*'")" 'push of a feature namespace glob, repo on a feature branch'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy "git push origin 'refs/tags/*'")" 'push of a tag glob, repo on main'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push origin --tags')" 'push --tags, repo on a feature branch'

# A git alias stands in for the subcommand, so it is resolved from the checkout's
# config before the rules run. These aliases are defined in the scratch repositories
# only; the global config is pinned to /dev/null above, so a developer's own aliases
# cannot make a case pass or fail.
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
  git -C "$scratch/$repo" config alias.push status      # hides a built-in: git ignores it
done
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git p --force origin feature')" 'git p --force (alias.p = push)'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git p -f origin feature')" 'git p -f'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git p origin main')" 'git p origin main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git p')" 'bare git p, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-main" shell_policy 'git p origin')" 'git p origin, repo on main'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git c -n -m x')" 'git c -n (alias.c = commit -am)'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git c --amend')" 'git c --amend'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git -C . c --amend')" 'alias behind a global option'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git pf origin feature')" 'git pf (alias.pf = push --force)'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git pp origin main')" 'git pp origin main (alias.pp = p -u, nested)'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git nuke')" 'git nuke (alias.nuke = !rm -rf build)'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy '/usr/bin/git p --force')" 'alias through a path on the command'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git PF origin feature')" 'an alias name is read case-insensitively, as git reads it'
report block "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git push --force origin feature')" 'alias.push cannot hide the built-in push'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git -c alias.p=status p --force origin feature')" 'a -c alias overrides the config file, as in git (p is now status)'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git p origin feature')" 'git p origin feature'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git c -m x')" 'git c -m x'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git lg -5')" 'git lg (alias with a quoted format)'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git loop1')" 'an alias cycle resolves without hanging'
report allow "$(CLAUDE_PROJECT_DIR="$scratch/on-feature" shell_policy 'git undefined-alias --force')" 'a word that is no alias is left alone'

# In production the policy reads the developer's global config as well, which is
# where most aliases live; the harness pins that file to /dev/null, so this section
# hands it one of its own. The last case is the pin's own regression test: with the
# pin removed, HOME's config would resolve `p` and the verdict would flip.
echo
echo "layer 2: the global git config"
mkdir -p "$scratch/home"
printf '[alias]\n\tp = push\n\tstatus = !rm -rf build\n' > "$scratch/home/.gitconfig"
report block "$(GIT_CONFIG_GLOBAL="$scratch/home/.gitconfig" shell_policy 'git p --force origin feature')" 'a global alias is resolved'
report allow "$(GIT_CONFIG_GLOBAL="$scratch/home/.gitconfig" shell_policy 'git status')" 'a global alias cannot hide the built-in status'
report allow "$(HOME="$scratch/home" shell_policy 'git p --force origin feature')" 'the harness does not read the developer'"'"'s own global config'

echo
echo "layer 2: data must not be mistaken for commands"
report block "$(shell_policy 'psql -c "DROP TABLE documents"')" 'psql -c "DROP TABLE documents"'
report allow "$(shell_policy 'git commit -m "feat(db): drop table legacy_pages in a migration"')" 'commit message naming DROP TABLE'
# SQL reads any run of whitespace between keywords, and more than DROP TABLE
# destroys data (#278).
report block "$(shell_policy 'psql -c "DROP  TABLE documents"')" 'DROP TABLE with two spaces'
report block "$(shell_policy $'psql -c "DROP\tTABLE documents"')" 'DROP TABLE with a tab'
report block "$(shell_policy $'psql -c "DROP\nTABLE documents"')" 'DROP TABLE across a newline'
report block "$(shell_policy 'psql -c "DROP DATABASE doctrans_dev"')" 'DROP DATABASE'
report block "$(shell_policy 'psql -c "DROP SCHEMA public CASCADE"')" 'DROP SCHEMA'
report block "$(shell_policy 'psql -c "DROP OWNED BY doctrans"')" 'DROP OWNED'
report block "$(shell_policy 'psql -c "TRUNCATE documents"')" 'TRUNCATE without TABLE'
report block "$(shell_policy 'psql -c "truncate only documents"')" 'TRUNCATE ONLY'
report block "$(shell_policy 'psql -c "DELETE FROM documents"')" 'DELETE FROM'
report block "$(shell_policy 'psql -c "delete from documents where id = 1"')" 'a lower-case DELETE FROM with a WHERE'
report block "$(shell_policy 'mysql -e "DELETE FROM documents"')" 'DELETE FROM through mysql'
report allow "$(shell_policy 'psql -c "DROP INDEX documents_title_idx"')" 'DROP INDEX loses no data'
report allow "$(shell_policy 'psql -c "SELECT count(*) FROM documents"')" 'harmless SQL'
report allow "$(shell_policy "psql -c \"SELECT * FROM documents WHERE title LIKE '%truncate%'\"")" 'a value naming truncate'
report allow "$(shell_policy 'truncate -s 0 dev.log')" 'the coreutils truncate'
report allow "$(shell_policy 'docker compose exec db psql -U doctrans -c "\dt"')" 'psql listing tables'
report allow "$(shell_policy 'git commit -m "fix(db): delete from documents cascades to pages"')" 'commit message naming DELETE FROM'
report allow "$(shell_policy 'git commit -m "feat(db): drop schema legacy in a migration"')" 'commit message naming DROP SCHEMA'
# A statement that takes columns with it, a client the first list missed, and the
# command the SQL belongs to: one command between separators, a pipe joining
# its halves (#278).
report block "$(shell_policy 'psql -c "DROP EXTENSION vector CASCADE"')" 'DROP EXTENSION CASCADE takes its columns with it'
report block "$(shell_policy 'psql -c "DROP TYPE embedding CASCADE"')" 'DROP TYPE CASCADE takes its columns with it'
report block "$(shell_policy 'psql -c "ALTER TABLE documents DROP COLUMN body"')" 'DROP COLUMN'
report block "$(shell_policy 'sqlite3 x.db "DROP TABLE documents"')" 'DROP TABLE through sqlite3'
report block "$(shell_policy 'echo "DROP TABLE documents" | psql')" 'SQL piped into psql'
report block "$(shell_policy 'ls && psql -c "DELETE FROM documents"')" 'destructive SQL after another command'
report block "$(shell_policy 'psql -c "SELECT 1; DROP TABLE documents"')" 'a semicolon inside the quoted SQL does not split the command'
report allow "$(shell_policy 'psql -c "DROP EXTENSION IF EXISTS vector"')" 'DROP EXTENSION without CASCADE loses no data'
report allow "$(shell_policy 'psql -c "DROP TYPE embedding"')" 'DROP TYPE without CASCADE loses no data'
report allow "$(shell_policy 'psql -c "ALTER TABLE documents DROP CONSTRAINT documents_pkey"')" 'DROP CONSTRAINT loses no data'
report allow "$(shell_policy 'psql -c "ALTER TABLE documents ALTER COLUMN body DROP NOT NULL"')" 'DROP NOT NULL loses no data'
report allow "$(shell_policy 'psql -c "\dt"; truncate dev.log')" 'the coreutils truncate after a psql command'
report allow "$(shell_policy 'psql -c "\dt" || truncate dev.log')" 'the coreutils truncate after a failed psql command'
report allow "$(shell_policy 'psql -c "\dt" && git commit -m "fix: delete from documents cascades"')" 'a commit message naming DELETE FROM after a psql command'
report allow "$(shell_policy 'docker exec app sh -c "echo delete from cart"')" 'docker exec alone is not a database client'
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
report block "$(shell_policy $'psql doctrans_dev <<SQL\nDELETE FROM documents;\nSQL')" 'DELETE FROM fed through a heredoc'
report block "$(shell_policy $'psql doctrans_dev <<SQL\nTRUNCATE\n  documents;\nSQL')" 'a heredoc statement split across lines'
report allow "$(shell_policy $'cat <<EOF\nrm -rf build\nEOF')" 'heredoc body naming rm -rf'
report allow "$(shell_policy $'cat <<"EOF" > notes.md\nnever run git reset --hard\nEOF')" 'quoted-delimiter heredoc body naming the rules'
report allow "$(shell_policy $'psql doctrans_dev <<SQL\nSELECT count(*) FROM documents;\nSQL')" 'harmless SQL fed through a heredoc'
report allow "$(shell_policy $'cat <<EOF > notes.md\npsql: never drop table by hand\nEOF')" 'heredoc written to a file naming psql and DROP TABLE'
report allow "$(shell_policy $'git commit -F - <<EOF\nfix(db): psql no longer runs drop table\nEOF')" 'heredoc commit message naming psql and DROP TABLE'
report allow "$(shell_policy 'grep <<<"rm -rf build" notes.md')" 'here-string holding rm -rf'

# The policy fails closed: when it cannot read the tool call or cannot run its
# rules, the command is refused, not waved through. Each case runs the policy on
# a PATH that holds only the tools it needs, with jq or awk left out or replaced
# by one that fails, and on a harmless command, so a block can only come from the
# failure.
tools_bin() { # dir tool... -- a PATH directory holding exactly these tools
  mkdir -p "$1" || return 1
  local dir=$1 tool; shift
  for tool in "$@"; do ln -sf "$(command -v "$tool")" "$dir/$tool" || return 1; done
}
broken_tool() { # dir tool -- a tool that always fails
  printf '#!/bin/sh\nexit 3\n' > "$1/$2" && chmod +x "$1/$2"
}
policy_on_path() { # path input [--json] -> block|allow
  local out status
  out=$(printf '%s' "$2" | PATH="$1" "$policy" ${3:+"$3"} 2>/dev/null); status=$?
  if [ "$status" -eq 2 ] || [[ "$out" == *'"permissionDecision":"deny"'* || "$out" == *'"permissionDecision": "deny"'* ]]; then
    echo block
  else
    echo allow
  fi
}
harmless='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
tools_bin "$scratch/bin-full" bash git jq awk
tools_bin "$scratch/bin-no-jq" bash git awk
tools_bin "$scratch/bin-no-awk" bash git jq
tools_bin "$scratch/bin-bad-jq" bash git awk && broken_tool "$scratch/bin-bad-jq" jq
tools_bin "$scratch/bin-bad-awk" bash git jq && broken_tool "$scratch/bin-bad-awk" awk

echo
echo "layer 2: a policy that cannot check the command refuses it"
report allow "$(policy_on_path "$scratch/bin-full" "$harmless")" 'a harmless command with jq and awk present (control)'
report allow "$(policy_on_path "$scratch/bin-full" '{"tool_name":"Read","tool_input":{}}')" 'a tool call with no command'
report block "$(policy_on_path "$scratch/bin-no-jq" "$harmless")" 'jq missing from PATH'
report block "$(policy_on_path "$scratch/bin-no-jq" "$harmless" --json)" 'jq missing from PATH, --json'
report block "$(policy_on_path "$scratch/bin-no-awk" "$harmless")" 'awk missing from PATH'
report block "$(policy_on_path "$scratch/bin-bad-jq" "$harmless")" 'jq that fails'
report block "$(policy_on_path "$scratch/bin-bad-jq" "$harmless" --json)" 'jq that fails, --json'
report block "$(policy_on_path "$scratch/bin-bad-awk" "$harmless")" 'awk that fails'
report block "$(policy_on_path "$scratch/bin-bad-awk" "$harmless" --json)" 'awk that fails, --json'
report block "$(policy_on_path "$scratch/bin-full" '{"tool_input": ')" 'malformed JSON on stdin'
report block "$(policy_on_path "$scratch/bin-full" '')" 'nothing on stdin'
report block "$(policy_on_path "$scratch/bin-full" '42')" 'JSON that is not a tool call'

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
  report block "$(native_policy git remote rm origin)" 'git remote rm'
  report block "$(native_policy git config remote.origin.url https://github.com/x/y.git)" 'git config remote.origin.url'
  report block "$(native_policy git config --local remote.origin.pushurl https://github.com/x/y.git)" 'git config --local remote.origin.pushurl'
  report block "$(native_policy git config set remote.origin.url https://github.com/x/y.git)" 'git config set remote.origin.url'
  report block "$(native_policy git config --unset remote.origin.url)" 'git config --unset remote.origin.url'
  report block "$(native_policy git config --global remote.origin.url https://github.com/x/y.git)" 'git config --global remote.origin.url'
  report block "$(native_policy git config --remove-section remote.origin)" 'git config --remove-section remote.origin'
  report block "$(native_policy git config rename-section remote.origin remote.upstream)" 'git config rename-section remote.origin'
  report block "$(native_policy rm -rf build)" 'rm -rf build'
  report block "$(native_policy rmdir d)" 'rmdir'
  report block "$(native_policy mix ecto.drop)" 'mix ecto.drop'
  report block "$(native_policy mix do ecto.drop)" 'mix do ecto.drop'
  report block "$(native_policy mix do ecto.drop, ecto.create)" 'mix do ecto.drop, ecto.create'
  report block "$(native_policy mix do ecto.reset)" 'mix do ecto.reset'
  report block "$(native_policy mix ecto.rollback --all)" 'mix ecto.rollback'
  report block "$(native_policy mix do ecto.rollback, ecto.migrate)" 'mix do ecto.rollback, ecto.migrate'
  report block "$(native_policy docker volume rm v)" 'docker volume rm'
  report block "$(native_policy docker volume remove v)" 'docker volume remove'
  report block "$(native_policy gh api -X DELETE repos/x/y)" 'gh api -X DELETE'
  report block "$(native_policy git checkout -f main)" 'git checkout -f'
  report block "$(native_policy git checkout -B feature origin/main)" 'git checkout -B'
  report block "$(native_policy git switch -C feature)" 'git switch -C'
  report block "$(native_policy git reflog delete 'HEAD@{1}')" 'git reflog delete'
  report block "$(native_policy git prune --expire=now)" 'git prune'
  report block "$(native_policy git update-ref refs/heads/main HEAD~5)" 'git update-ref'
  report block "$(native_policy git branch -f main HEAD~5)" 'git branch -f'
  report block "$(native_policy git branch -M main)" 'git branch -M'
  report block "$(native_policy git tag -d v1.0.0)" 'git tag -d'
  report block "$(native_policy git tag -f v1.0.0)" 'git tag -f'
  report block "$(native_policy git push -d origin feature)" 'git push -d'
  report block "$(native_policy git push -fu origin feature)" 'git push -fu'
  report block "$(native_policy git push --prune origin)" 'git push --prune'
  report block "$(native_policy git push --force-if-includes origin feature)" 'git push --force-if-includes'
  report block "$(native_policy git gc --prune=now)" 'git gc --prune=now'
  report block "$(native_policy git config core.hooksPath /dev/null)" 'git config core.hooksPath'
  report allow "$(native_policy git status)" 'git status'
  report allow "$(native_policy git push origin feature)" 'git push origin feature'
  report allow "$(native_policy git checkout -b feature origin/main)" 'git checkout -b'
  report allow "$(native_policy git branch -d feature)" 'git branch -d'
  report allow "$(native_policy git tag -a v1.0.0 -m release)" 'git tag -a'
  report allow "$(native_policy git gc)" 'git gc'
  report allow "$(native_policy git config user.name x)" 'git config user.name'
  report allow "$(native_policy git config --get remote.origin.url)" 'git config --get remote.origin.url'
  report allow "$(native_policy git remote get-url origin)" 'git remote get-url'
  report allow "$(native_policy gh pr merge 1 --squash)" 'gh pr merge'
  report allow "$(native_policy mix test)" 'mix test'
  report allow "$(native_policy rm stale.log)" 'rm stale.log'
else
  echo "layer 1: skipped (codex CLI not installed)"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
