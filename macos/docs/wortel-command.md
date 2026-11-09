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

### `wortel new [--cwd <path>] [--name <name>] [--branch <branch>] [--from <ref>] [--pr <n|url>] [--worktree] [-- <command>]`

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

Anything after `--` is a **command for the new session to run**, its own flags
included. It is typed into the session's shell as its first line rather than
run in place of the shell, so it goes in your history, the sidebar sees an
agent start exactly as if you'd typed it (status, naming, resume after a
relaunch), and when it exits you're at a prompt in that directory instead of
looking at a closed terminal. It works with every form of `new`; a worktree
session runs it once the worktree is ready.

```sh
wortel new --cwd ~/code/x -- claude --resume 7f3c9a1e
wortel new --worktree --name "login redirect" -- claude "fix the login redirect"
wortel new --pr 1482 -- make test
```

The words arrive as your shell split them and run as those words: one with a
space or a quote in it is quoted for you, and nothing is expanded a second
time. For a pipeline or a `&&`, hand it to a shell yourself:
`-- sh -c 'make && make test'`.

Two kinds of command are refused, with exit status 2, because typing them would
go wrong: one longer than 1024 bytes (the most a terminal holds of a line
before the shell starts reading, past which the whole line is thrown away), and
one with a tab or another control character in it, which the shell would take
as a key. A newline inside an argument is fine. For anything bigger, put it in
a script and run that. If the command could not be typed for any other reason,
`wortel new` exits 1 and says so, so a script can fall back to something else.

`wortel` is on the `PATH` inside Wortel sessions only. A script started from
somewhere else (a launcher, a hotkey app, a button) can call it by its full
path, `/Applications/Wortel.app/Contents/Resources/bin/wortel`.

### `wortel rename [--session <s>] <name>`

Renames **the session you're in**, or with `--session` another one (an id or a
name, as below). A `/` in the name puts it in that folder in the sidebar.

```sh
wortel rename "1482 login redirect"
wortel rename "Lijn/css rules"
```

A rename this way counts as *yours*, so auto-naming will never overwrite it.

### `wortel notify [--session <s>] <title> [body]`

Raises attention on the session you're in (or the one `--session` names): the
sidebar dot, the Dock badge, and a notification.

```sh
npm test || wortel notify "Tests failed" "$(git branch --show-current)"
make && wortel notify "Build done"
```

This is the same path an agent's own escape sequence takes, so a build finishing
and Claude finishing look and sound identical — which is the point when you're
in another room.

### `wortel mark [--session <s>] <colour>`

Colours the session you're in (or the one `--session` names), as a bar at the edge of its row in the
sidebar: red, orange, yellow, green, blue, purple or grey. `wortel mark none`
takes it off. The same colours are in the row's menu, under Colour.

```sh
gh pr create --fill && wortel mark yellow
wortel mark none
```

A colour is a note to yourself, and only you take it off: opening the session
leaves it. Use it for a session you're nearly done with but want to keep, like
a review waiting on CI.

## Reaching other sessions

The commands above act on the session they're run in. These four act on any
open session, which is what lets one agent start another, give it a prompt,
wait for it to finish and read what it said. They go through the same doors
you do: the screen, a paste and the Return key. Nothing asks for permission and
nothing marks the text as sent by a program: to the session, `send` is someone
typing.

### `wortel list [--json]`

The open sessions, in sidebar order:

```
$ wortel list
  ID       NAME                  STATE     AGENT  BRANCH          DIRECTORY
* 3F2A91C0 Wortel/website        working   claude -               ~/Developer/wortel
  9B1E07D2 Wortel/tests (you)    idle      -      -               ~/Developer/wortel
  C04D11A8 fix login redirect    needs-you codex  fix/1482        ~/.wortel/worktrees/wortel/fix-1482
```

`*` is the session selected in the sidebar, and `(you)` the one you ran the
command in. The state is what the sidebar's dots say:

| State | Means |
|---|---|
| `working` | a command or an agent's turn is running |
| `needs-you` | it's asking for you: a permission, a question, a bell |
| `finished` | its last turn or long command ended cleanly |
| `failed` | its last turn or long command ended in an error |
| `idle` | nothing running, nothing said since |
| `preparing` | its worktree is still being made |

`--json` prints the same as an array of objects with the fields `id`, `name`,
`folder`, `directory`, `branch`, `worktree`, `agent`, `state`, `selected` and
`caller`. A field with nothing to say is left out rather than `null`. The field
names are a contract: new ones may be added, none will be renamed.

### Naming a session

Wherever a command takes `<session>` (and `--session` on `rename`, `notify`
and `mark`) you can give:

- its **id**, the whole one or the short one `list` prints (any start of four
  characters or more);
- its **name**, as the sidebar shows it (`website`) or with its folder
  (`Wortel/website`), in any case;
- the **start of a name**, when only one session's name starts that way.

An exact name wins over a prefix, so a session called `Agent` is still
reachable beside `agent one` and `agent two`. When a name could mean two
sessions the command refuses and lists them, rather than picking one: a prompt
typed into the wrong agent can't be taken back.

### `wortel read <session> [--lines <n>] [--json]`

Prints the text on a session's screen, as plain text: no colours, trailing
spaces and the empty rows under the last line trimmed.

```sh
wortel read website
wortel read website --lines 200     # the last 200 lines, scrollback included
```

`--lines` takes up to 10000.

It's the screen as the program last drew it, not wherever someone has
scrolled to. For a full-screen agent that includes its frame and input box.
`--json` prints `{"id", "name", "text"}`.

A session restored at launch that hasn't been shown since has no terminal yet;
`read` (like `send` and `wait`) starts it quietly, without selecting it, and
reads it once what it printed while Wortel was away is back on its screen.

### `wortel send <session> [text] [--enter] [--stdin]`

Types `text` into the session as a paste: exactly what ⌘V would do with it on
your clipboard. To an agent that asked for bracketed paste (they all do), a
multi-line prompt arrives as one input in its box, not as one message per line.
Nothing is added in front of it.

```sh
wortel send tests "run the unit tests and fix what fails" --enter
wortel send tests --enter                 # just press Return
git diff | wortel send review --stdin --enter
wortel send tests -- --help               # text that starts with a dash
```

`--enter` presses Return after the paste, as its own keypress a moment later,
the way you would. `--stdin` reads the text from standard input and drops one
trailing newline, as `$(...)` does. The session is not selected and nothing
takes focus, so you can keep typing where you are. Sending to the session you're
in works too. Up to 256 KB at a time.

### `wortel wait <session> [--for <text> [--from-start]] [--idle] [--exit] [--timeout <dur>]`

Waits until something happens in a session, then exits 0:

- `--for <text>`: the text appears. It's matched against the plain text, so
  colours and bold can't split it, and it counts only when it's **new**: text
  already on the screen or in the scrollback when the wait starts doesn't end
  it. `--from-start` counts what's already there too.
- `--idle`: the agent in it has finished its turn or is waiting on you (a
  question, a permission), or a plain shell is back at its prompt. A wait that
  starts right after a `send` waits for the agent to start first, so it can't
  end before the work does. A session nobody has touched is idle at once.
- `--exit`: the session closes, or its shell exits.

With none of these, it waits for `--idle`. With several, the first to happen
ends it, and its name (`text`, `idle` or `exit`) is printed.

`--timeout` is how long to wait: `30s` unless given, as `90s`, `5m`, `1h` or a
bare number of seconds, up to 7 days, and `0` for no limit.

| Exit status | Means |
|---|---|
| `0` | it happened |
| `124` | the time ran out (the status `timeout(1)` uses) |
| `1` | it couldn't wait: no such session, or it closed first |
| `2` | you typed it wrong |

`--for` is for output you know the shape of, like a dev server saying it's up:

```sh
wortel send server "npm run dev" --enter
wortel wait server --for "ready in" --timeout 1m
```

Pick text the command or prompt itself doesn't contain: what you `send` is on
the screen too, and would count.

### One agent running another

An agent (or a script) in one session starts a second agent in a worktree of
its own with a task, waits for it to finish, reads what it said, and gives it
the next step:

```sh
id=$(wortel new --worktree --name "flaky test" -- claude "Find out why LoginTests.testRedirect is flaky")
wortel wait "$id" --idle --timeout 20m
wortel read "$id" --lines 80

wortel send "$id" "Fix it, and run the tests until they pass." --enter
wortel wait "$id" --idle --timeout 20m && wortel read "$id" --lines 40
```

The first task goes on `new`'s command line rather than through `send`: the
agent isn't there to paste into until it has started. The second agent is in
the sidebar the whole time, so you can watch it work, answer it yourself, or
take it over. Its id is the only thing the first one has to keep.

## Which session a command means

`rename`, `notify` and `mark` act on the session they were run in, unless given `--session`. You never pass an id:
every Wortel shell carries `$WORTEL_SESSION_ID`, and the command reads it. Run
from outside Wortel they say so instead of guessing:

```
Not running inside a Wortel session (no $WORTEL_SESSION_ID).
```

That's inherited by anything the shell starts, so a hook, a script, or an agent
several processes deep still means the right session.

## For scripting

- **stdout** carries the one machine-readable value (a session id, a path),
  or the answer itself for `list` and `read`.
- **stderr** carries anything meant for a person.
- **Exit codes:** `0` it happened, `1` the app said no, `2` you typed it wrong,
  and `124` for a `wait` that ran out of time.

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

**`"agent" could be "agent one" (3F2A91C0), "agent two" (3F2B0000).`** The
name you gave starts more than one session's. Use more of it, or the id.
