#!/bin/bash
# A throwaway repository with every git situation the panel has to handle, and
# a session in it, so a build can be looked over in five minutes before it
# ships. The UI has no automated tests; almost every git bug reported so far
# is one this repo shows at a glance.
#
#   scripts/try-git.sh          build it and open a session (run inside Wortel)
#   scripts/try-git.sh --clean  remove everything it made
#
# What's in it:
#   shop/                     main: 4 commits not pushed, 1 on the remote you
#                             don't have (↑4 ↓1: Pull and Push both refuse,
#                             in a sentence), clean, so the Changes pane points
#                             at the work in another folder
#   shop-toolbar-clean/       me/toolbar-clean, clean and pushed: Bring Here
#   shop-toolbar-proposal/    me/toolbar-proposal, 19 new files: Show only
#   shop-agent-running/       me/agent-running, something running in it:
#                             Bring Here says why not
#   ~/.wortel/worktrees/...   worktree/calm-test, made "by Wortel": Bring Here
#                             moves it to the Trash; worktree/squashed and
#                             worktree/picked, whose work main has without
#                             their commits: Clean Up says Merged
#   shop-fork-me/             me/fork-me, every kind of uncommitted change,
#                             a .env, a .worktreeinclude, a nested repo: what
#                             Fork Session and the file copy have to carry
#   origin pull requests      refs/pull/7/head (a commit on no branch) and
#                             refs/pull/8/head (me/shape-lab's tip)
#   branches                  me/shape-lab (2d), me/old-idea (3w),
#                             me/conflict (switching with README.md edited
#                             says which file is in the way), origin/me/remote-only
set -euo pipefail

BASE=/tmp/wortel-try-git
WORTEL_TREE="$HOME/.wortel/worktrees/wortel-try-git"
PIDFILE="$BASE/running.pid"

clean() {
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE")
    # Only our sleep: a recycled pid could be anything.
    if ps -o command= -p "$pid" 2>/dev/null | grep -q "sleep 86400"; then kill "$pid"; fi
  fi
  if [ -d "$BASE/shop" ]; then
    # Every worktree the app made for this repo (forks, pull requests, new
    # branches): only those registered here, never a folder by its name.
    git -C "$BASE/shop" worktree list --porcelain | sed -n 's/^worktree //p' | while read -r tree; do
      case "$tree" in "$HOME/.wortel/worktrees/"*) git -C "$BASE/shop" worktree remove --force "$tree" 2>/dev/null || true ;; esac
    done
  fi
  rm -rf "$BASE" "$WORTEL_TREE"
  echo "Removed $BASE and the worktree Wortel made for it. Close the \"Try git\" session with ⇧⌘W."
}

if [ "${1:-}" = "--clean" ]; then clean; exit 0; fi
[ -e "$BASE" ] && clean >/dev/null

mkdir -p "$BASE" && cd "$BASE"
export GIT_AUTHOR_NAME="Try Git" GIT_AUTHOR_EMAIL="try@wortel.sh"
export GIT_COMMITTER_NAME="Try Git" GIT_COMMITTER_EMAIL="try@wortel.sh"
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q --allow-empty -m "$2"; }
ago() { date -v-"$1" +%Y-%m-%dT%H:%M:%S; }

git init -q --bare -b main origin.git
git init -q -b main shop && cd shop
echo "# Shop" > README.md && git add . && at "$(ago 40d)" "Start the shop"
git remote add origin ../origin.git && git push -q -u origin main

# Branches of different ages, one that only the remote has, one that touches
# README.md so a local edit to it is in the way of switching.
git branch me/old-idea && git checkout -q me/old-idea && at "$(ago 21d)" "An old idea"
git checkout -q -b me/shape-lab main && at "$(ago 2d)" "Shapes" && git push -q -u origin me/shape-lab
git checkout -q -b me/remote-only main && at "$(ago 5d)" "Only on the remote" \
  && git push -q origin me/remote-only && git checkout -q main && git branch -q -D me/remote-only
git checkout -q -b me/conflict main && echo "# Shop, renamed" > README.md && git commit -q -am "Rename the shop"
git checkout -q main

# The remote moves on without us, and we move on without it: ↑2 ↓1.
git clone -q ../origin.git ../elsewhere
(cd ../elsewhere && at "$(ago 1d)" "Someone else's commit" && git push -q)
rm -rf ../elsewhere
git fetch -q
at "$(ago 3H)" "Local work 1" && at "$(ago 1H)" "Local work 2"

# Agent folders.
git worktree add -q -b me/toolbar-clean ../shop-toolbar-clean
(cd ../shop-toolbar-clean && echo toolbar > toolbar.txt && git add . && git commit -q -m "Toolbar" \
  && git push -q -u origin me/toolbar-clean)
git worktree add -q -b me/toolbar-proposal ../shop-toolbar-proposal
(cd ../shop-toolbar-proposal && for i in $(seq 1 19); do echo "draft $i" > "draft-$i.txt"; done)
git worktree add -q -b me/agent-running ../shop-agent-running
# `exec`, so the pid saved is the sleep itself, which is what --clean stops.
(cd ../shop-agent-running && exec nohup sleep 86400 >/dev/null 2>&1) & echo $! > "$PIDFILE"
mkdir -p "$WORTEL_TREE"
git worktree add -q -b worktree/calm-test "$WORTEL_TREE/calm-test"
(cd "$WORTEL_TREE/calm-test" && echo calm > calm.txt && git add . && git commit -q -m "Calm test")

# Work main has without the commits: squash-merged, and cherry-picked as a
# rebase merge would. Their own commits are on no other branch.
git worktree add -q -b worktree/squashed "$WORTEL_TREE/squashed"
(cd "$WORTEL_TREE/squashed" && echo one > squash.txt && git add . && git commit -q -m "Squash one" \
  && echo two >> squash.txt && git commit -q -am "Squash two")
git merge -q --squash worktree/squashed >/dev/null && git commit -q -m "Squashed"
git worktree add -q -b worktree/picked "$WORTEL_TREE/picked"
(cd "$WORTEL_TREE/picked" && echo picked > picked.txt && git add . && git commit -q -m "Picked")
git cherry-pick worktree/picked >/dev/null

# Pull requests, as GitHub publishes them: one from a fork (on no branch
# here) and one pushed from a branch of this repository.
git checkout -q -b pr-seven main && echo seven > seven.txt && git add . && git commit -q -m "Pull request seven" \
  && git push -q origin pr-seven:refs/pull/7/head && git checkout -q main && git branch -q -D pr-seven
git push -q origin me/shape-lab:refs/pull/8/head

# Something to fork: every kind of uncommitted change, ignored files to copy
# and one not to, and a nested repository the fork must skip.
git worktree add -q -b me/fork-me ../shop-fork-me
(cd ../shop-fork-me \
  && printf '.env*\nconfig/local.json\nnode_modules/\n' > .gitignore \
  && printf '.env*\nconfig/local.json\n' > .worktreeinclude \
  && echo "run" > run.sh && git add . && git commit -q -m "Fork material" \
  && echo "SECRET=1" > .env && mkdir -p config node_modules/pkg \
  && echo '{"local":true}' > config/local.json && echo "NOPE=1" > node_modules/pkg/.env \
  && echo "staged" > staged.txt && git add staged.txt \
  && echo "# Shop, staged" > README.md && git add README.md && echo "# Shop, staged, then more" > README.md \
  && chmod +x run.sh && head -c 4096 /dev/urandom > blob.bin \
  && mkdir -p vendor/lib && git -C vendor/lib init -q)

if command -v wortel >/dev/null 2>&1; then
  wortel new --cwd "$BASE/shop" --name "Try git" >/dev/null
  wortel new --cwd "$BASE/shop-fork-me" --name "Try fork" >/dev/null
  echo "Opened the \"Try git\" and \"Try fork\" sessions in $BASE."
else
  echo "Built $BASE/shop. Run this inside Wortel to get a session opened in it."
fi

cat <<'EOF'

Look over, with the git panel open (⇧⌘C):
  [ ] Changes says "No changes here" with a link to shop-toolbar-proposal
  [ ] Branch list: This folder (main ↑4 ↓1), In other folders, Switch to, Remote
  [ ] me/toolbar-proposal: Show, and "19 changes there"
  [ ] me/agent-running: Bring Here says something is running there
  [ ] me/toolbar-clean and worktree/calm-test: Bring Here works
  [ ] origin/me/remote-only: checks out as a new local branch
  [ ] … › Pull and … › Push: each refuses in one sentence
  [ ] Edit README.md, then switch to me/conflict: names README.md
  [ ] Run two servers in the session, open the running list: Stop All
      python3 -m http.server 8801 & python3 -m http.server 8802 &
  [ ] Session › Worktree › Clean Up Worktrees: squashed and picked say
      "Merged · branch too"; calm-test says "Branch kept"
  [ ] Open worktree/squashed: Changes says "Merged into main"
  [ ] echo $WORTEL_PORT in two sessions: different; after a relaunch, the same
  [ ] New Worktree Session (⌥⇧⌘N): the row's shell starts in its worktree,
      not /, in this folder; ask the agent something and the branch is
      renamed for the session's name (git branch)
  [ ] Close (⇧⌘W) a worktree session with changes: it leaves the sidebar;
      ⌘P lists it as Archived once you type its name; pick it: back in its
      worktree, agent resumed
  [ ] Close a fresh, untouched worktree session: its folder is in the Trash
      a moment later, and ⌘P doesn't list it
  [ ] exit in a worktree session: archived, like closing it
  [ ] New Worktree Session (⌥⇧⌘N) › Location, pick ../shop-trees: the next
      ⌥⇧⌘N lands there; Wortel's Worktree Folder puts it back
  [ ] ⌘O on ../shop-toolbar-proposal: lands in the shop folder, not a new
      one, named for its branch; rename it and the branch shows under it
  [ ] cd ../shop-toolbar-clean in a session: the branch line appears
  [ ] Git panel › worktree chip › shop-toolbar-clean › Open Session: goes to
      that session

Done: scripts/try-git.sh --clean
EOF
