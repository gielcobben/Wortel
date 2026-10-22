# `wortel` — using the command

A guide to what the command line tool does. For *why* it is built the way it is
— the socket, the no-installer decision, the case-insensitivity traps — see
[cli.md](cli.md).

## There is nothing to install

The command ships inside the app. Open any Wortel session and it's there:

```sh
$ wortel --version
wortel 2026.32.1 (/Applications/Wortel.app)
Wortel 2026.32.1 (412)
```

The first line is the command; the second is the app that answered it. If the
app's path appears on the second line too, you are running a `wortel` from a
*different* bundle than the app that's running — worth knowing, because the two
ship together.

It works in any shell Wortel starts an integration for (zsh, bash, fish). It is
not on your `PATH` in Terminal.app or iTerm, by design.

## The commands

### `wortel open <path>`

Opens a file in a preview window — the same window a double-click in the Files
pane gives you: source, diff, or rendered Markdown depending on the file.

```sh
wortel open README.md                  # relative to where you are
wortel open ~/Developer/lijn/App.swift
```

Relative paths resolve against **your** working directory, not the app's. The
window is ordered front but **never steals focus** — if you're in another app it
waits for you rather than yanking you out of what you were doing.

Directories are refused rather than guessed at; use `wortel new --cwd` for those.

### `wortel new [--cwd <path>] [--name <name>] [--branch <branch>] [--from <ref>] [--pr <n|url>] [--worktree]`

Starts a session. With no arguments it opens one in your current directory.

```sh
wortel new
wortel new --cwd ~/Developer/lijn --name "css rules"
wortel new --branch fix/1482 --name "1482 login redirect"
wortel new --branch fix/1482 --from release/2026
```

`--branch` gives the session **its own git worktree** — its own branch and its
own files — so an agent working in it can't collide with anything else you have
open. A branch that already has a worktree is reused rather than duplicated.

A new worktree also gets the **ignored files the project needs to run**, copied
from the checkout you ran the command in: whatever `.worktreeinclude` at its
root names (gitignore syntax, the file Claude Code, Codex and Conductor read
too), or `.env*` when there is none. Copies are instant APFS clones, nothing is
ever overwritten, and anything that couldn't be copied is printed after the
"Started" line.

The branch may be new, in which case `--from` says what it forks from. Left out,
that's **the repository's default branch** — `origin/HEAD` where it exists, then
`main`, then `master`, then whatever is checked out. It is deliberately *not*
`HEAD`: the command runs wherever you happen to be, and a script that fires from
inside one worktree would otherwise fork that worktree's branch instead of
trunk. To stack onto the current branch on purpose, say so:

```sh
wortel new --branch fix/1482-followup --from HEAD
```

`--from` takes anything git will resolve — a branch, a tag, a commit — and is
ignored for a branch that already exists, which is checked out as it is.

`--pr` checks out a pull request instead, by number or by its URL (GitHub's
`/pull/123` or GitLab's `/-/merge_requests/123`). Plain git, no `gh`: one
pushed from a branch of this repository is checked out as that branch, so you
can push to it; one from a fork lands on `worktree/pr-123`. Opening it again
reuses the worktree. The branch sheet takes the same thing: type `#123` or
paste the URL where the branch name goes.

```sh
wortel new --pr 1482 --name "review 1482"
```

`--worktree` is ⇧⌘N from a script: a worktree of its own on a new branch
Wortel names, from the default branch. The branch starts as a placeholder
(`worktree/brave-river-1a2f`) and is renamed for the session once it has a
name, as long as it hasn't been pushed.

```sh
wortel new --worktree --name "try a queue"
```

Worktrees go in `~/.wortel/worktrees/<repo>/<branch>` unless the repository
names its own place in git config, `wortel.worktreePath`: a folder, or a
template with `{repo}` and `{branch}`, relative to the repository or not. The
folder menu's Worktree Location… sets it; git's `includeIf` sets it for every
repository under a folder:

```ini
# ~/.gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
# ~/.gitconfig-work
[wortel]
    worktreePath = ~/work/worktrees/{repo}/{branch}
```

The repository comes from *where you ran the command*, not from whatever the
sidebar is pointing at. The new session's id goes to stdout:

```sh
id=$(wortel new --cwd ~/Developer/lijn)
```

### `wortel rename <name>`

Renames **the session you're in**. A `/` in the name puts it in that folder in
the sidebar.

```sh
wortel rename "1482 login redirect"
wortel rename "Lijn/css rules"
```

A rename this way counts as *yours*, so auto-naming will never overwrite it.

### `wortel notify <title> [body]`

Raises attention on the session you're in: the sidebar dot, the Dock badge, and
a notification.

```sh
npm test || wortel notify "Tests failed" "$(git branch --show-current)"
make && wortel notify "Build done"
```

This is the same path an agent's own escape sequence takes, so a build finishing
and Claude finishing look and sound identical — which is the point when you're
in another room.

### `wortel mark <colour>`

Colours the session you're in, as a bar at the edge of its row in the
sidebar: red, orange, yellow, green, blue, purple or grey. `wortel mark none`
takes it off. The same colours are in the row's menu, under Colour.

```sh
gh pr create --fill && wortel mark yellow
wortel mark none
```

A colour is a note to yourself, and only you take it off: opening the session
leaves it. Use it for a session you're nearly done with but want to keep, like
a review waiting on CI.

### `wortel fork [--name <name>] [--branch <branch>]`

Forks the session you're in: a new session in a worktree of its own, starting
at the same commit with the same uncommitted changes (staged stays staged,
untracked files come along), and the agent running there continuing a copy of
its conversation. The session you forked is not touched. Exactly what Fork
Session in the Session menu does (⌥⇧⌘N).

```sh
wortel fork --name "try it with a queue"
```

It's how an agent tries a second approach without losing the first: fork, and
the original carries on where it was. The new session's id goes to stdout once
its worktree is ready. Claude Code, Codex and Pi have their conversation
forked; any other agent's session forks its files and opens a shell. Outside a
repository there is nothing to isolate, so the fork opens in the same folder.

### `wortel cd <dir>`

Moves the session you're in to another directory, agent and all. The shell
`cd`s there, the session is filed under that directory's sidebar folder (a new
folder if none covers it, as ⌘O makes one), and the git panel and Files follow.
Exactly what Change Directory in the session menu does.

```sh
wortel cd ../new-site
```

It's for the conversation that wandered: you asked the agent to start a new
project next door, it made the folder and kept working there through its own
`cd`s, and the session, its git panel and its sidebar folder all stayed on the
old project. Run by the agent itself, the move waits for the end of its turn:

1. The agent finishes its reply. A turn waiting on a permission or a question
   isn't finished, and neither is one you're typing into.
2. Wortel quits it (SIGTERM, as a terminal ends a job).
3. `cd <dir>` and the agent's resume are typed into the shell, and the same
   conversation carries on in the new directory, waiting for you.

The command answers straight away and says what will happen ("Not moved yet.
When this turn ends, claude quits and continues this conversation in
~/Developer/new-site, then waits for you."), including any background task the
agent started that stops when it quits. In a plain shell the `cd` is typed as
soon as `wortel` exits. Claude Code's conversation is the one carried today;
any other agent is refused with a reason (quit it first, then move). Something
else in the foreground (vim, a dev server) is refused too, rather than typed
into. Run it again with another directory to change where it's going, or with
the one you're in to call it off.

## Which session a command means

`rename`, `notify`, `mark`, `fork` and `cd` act on the session they were run in. You never pass an id:
every Wortel shell carries `$WORTEL_SESSION_ID`, and the command reads it. Run
from outside Wortel they say so instead of guessing:

```
Not running inside a Wortel session (no $WORTEL_SESSION_ID).
```

That's inherited by anything the shell starts, so a hook, a script, or an agent
several processes deep still means the right session.

## For scripting

- **stdout** carries the one machine-readable value (a session id, a path).
- **stderr** carries anything meant for a person.
- **Exit codes:** `0` it happened, `1` the app said no, `2` you typed it wrong.

So `id=$(wortel new)` gives you an id and nothing else, and `wortel open x ||
echo nope` does what you'd expect.

## Recipes

### Name every agent session after what it's working on

Claude Code's `SessionStart` hook, in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ {
        "type": "command",
        "command": "wortel rename \"$(basename \"$PWD\")/$(git branch --show-current 2>/dev/null || echo shell)\""
      } ] }
    ]
  }
}
```

### Tell me when the agent wants something

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [ { "type": "command", "command": "wortel notify \"Claude needs you\"" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "wortel notify \"Claude finished\"" } ] }
    ]
  }
}
```

Wortel already infers both of these from the screen and from OSC signals, so
this is not required — it's for when you'd rather be told explicitly than
inferred at. The two arrive through the same channel either way.

### Show me the file you just wrote

Anything an agent can run, it can run this:

```sh
wortel open src/PreviewWindow.swift
```

No integration, no plugin, no adapter per agent. That's the whole reason the
command exists.

### From a ticket to a working session in one line

```sh
work() { wortel new --branch "fix/$1" --name "$1 ${2:-}"; }
work 1482 "login redirect"
```

### Notify on any long command

```sh
alias notify='wortel notify "Command finished"'
some-long-build; notify
```

## When something's wrong

**`command not found: wortel`** — you're not in a Wortel session, or you're in a
shell Wortel doesn't ship an integration for. Check with `echo $WORTEL_BIN_DIR`;
if that's empty, the app didn't start this shell.

**`Wortel isn't running.`** — the app has quit. The socket lives at
`~/Library/Application Support/Wortel/cli.sock`; a stale one left by a crash is
taken over on the next launch.

**`That session has closed.`** — the session your shell belongs to is gone, but
the process is still running. Ordinary for a background job that outlived its
row.

**`This Wortel doesn't understand that command.`** — the command and the app are
from different versions. `wortel --version` prints both.
