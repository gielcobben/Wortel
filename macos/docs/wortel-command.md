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

### `wortel new [--cwd <path>] [--name <name>] [--branch <branch>]`

Starts a session. With no arguments it opens one in your current directory.

```sh
wortel new
wortel new --cwd ~/Developer/lijn --name "css rules"
wortel new --branch fix/1482 --name "1482 login redirect"
```

`--branch` gives the session **its own git worktree** — its own branch and its
own files — so an agent working in it can't collide with anything else you have
open. A branch that already has a worktree is reused rather than duplicated. The
branch may be new; it's created from `HEAD`.

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

## Which session a command means

`rename` and `notify` act on the session they were run in. You never pass an id:
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
