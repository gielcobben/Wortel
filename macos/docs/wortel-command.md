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

Opens a file as a tab, the same view a double-click in the Files pane gives
you: source, diff, or rendered Markdown depending on the file. It opens beside
the session's terminal tab. (It was the side column until 2026-11-17.)

```sh
wortel open README.md                  # relative to where you are
wortel open ~/Developer/lijn/App.swift
```

An `.html` file opens as the page it makes, in a browser tab, and loads again
whenever the file changes on disk (or a stylesheet, script or picture it
loads from disk). `wortel open report.html` a second time brings that tab
forward. The tab's header has Page · Source for the file's text, and ⌥⌘U
flips between them.

```sh
wortel open report.html                # the page, reloading as you write it
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

`--worktree` is ⌥⇧⌘N from a script: a worktree of its own on a new branch
Wortel names, from the default branch. The branch starts as a placeholder
(`worktree/brave-river-1a2f`) and is renamed for the session once it has a
name, as long as it hasn't been pushed.

```sh
wortel new --worktree --name "try a queue"
```

Worktrees go in `~/.wortel/worktrees/<repo>/<branch>` unless the repository
names its own place in git config, `wortel.worktreePath`: a folder, or a
template with `{repo}` and `{branch}`, relative to the repository or not. The
New Worktree sheet's Location field sets it; git's `includeIf` sets it for
every repository under a folder:

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

Without `--`, the session is a plain shell, whatever Settings ▸ New sessions
start with says. That setting is for the sessions you start by hand; a script
says what it wants run.

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

### `wortel remind [--session <s>] <when>`

Brings the session back to you later, as Remind Me in the row's menu does:
when the time comes, the session gets the unread ring and you get a
notification. `<when>` is a duration (`20m`, `1h`, `2d`, `1w`, `in 2h`), a
time on the clock (`15:00`, `3pm`, `9:30am`: today if it's still ahead,
otherwise tomorrow), `tomorrow` or `next-week` (both at 9:00, next week being
Monday), or a day with or without a time (`fri`, `friday 14:00`, `tomorrow
3pm`, `2026-12-03 10:00`; a day alone means 9:00, and a weekday is the next one
still ahead). Several words need no quotes. `wortel remind none` cancels it.

```sh
gh pr create --fill && wortel remind 1h     # look at CI in an hour
wortel remind tomorrow
wortel remind fri 9am
wortel remind none
```

A session has one reminder; setting another replaces it. Opening the session
before then leaves it set, and closing the session ends it.

Claude Code learns all of this from a skill Wortel installs at launch,
`~/.claude/skills/wortel/SKILL.md`, kept up to date while you leave it as it
is. Edit it and Wortel stops touching it; delete it and it stays gone.

### `wortel cd <dir>`

Moves the session it was run in to another directory, with its agent's
conversation. Meant for the agent itself: a session that started in a folder
of its own under `~/Wortel` and turned into work on a project elsewhere. The
guide Wortel keeps in `~/Wortel/CLAUDE.md` tells Claude to offer the move and
to run this once you agree.

Nothing happens at once. When the agent's turn ends, Wortel quits it, types
`cd <dir>` into the same shell and resumes the same conversation there, then
the agent waits for you. The row is filed into the folder that covers `<dir>`,
or a new one, as ⌘O would. The git panel, and the agent's own settings, are
then that project's.

```sh
wortel cd ~/Developer/opmaak
```

Claude Code only. The move waits while a turn is running, a question is
waiting on you, something the agent started is still running, or you have
typed and not sent. If it can't happen within an hour, the session gets a red
dot and a notification and stays where it was. Anything the agent started that
is still running when it quits stops. A relative `<dir>` is read from where the
command was run. `wortel cd .` (the folder it is in) calls off a move that is
still waiting.

### `wortel close`

Closes the session it was run in, the way its row's × does, and removes its
worktree. Meant for the agent: tell it "we're done, delete this worktree" and
it runs this instead of `git worktree remove`, which it can't do from inside
the folder anyway. The skill Wortel installs tells Claude Code to.

Nothing happens at once. When the agent's turn ends, the session closes and
its worktree goes to the Trash, with its branch if Wortel made it and nothing
on it is unique. Where closing the row keeps a worktree with uncommitted or
untracked files, this one asks you, straight away, on the session's window:
**Move to Trash** takes them with it (they are in the Trash if you want them
back), **Keep Worktree** archives the session as a click does. A worktree
another tool made, one that's locked, or one another session is in is never
removed; the session is archived and ⌘P brings it back. If the worktree is
kept when you said to trash it (a new file appeared after you answered), a
sheet says why.

```sh
wortel close
```

Anything else still running in the session (a dev server) gets the same
question closing it by hand does. In a session that isn't in a worktree it
only closes the session. If the turn doesn't end within an hour, the session
gets a red dot and stays open. No `--session`: it closes the session it was
run in, and nothing else.

### `wortel split [right|down|left|up] [--session <s>] [-- <command>]`

Opens a new terminal in a split beside the session's main terminal: to the
right unless you say `down`, `left` or `up`. It starts in the
session's folder, as a terminal you open beside it by hand does. With a
command after `--`, that command is typed into the new shell and run, the way
`wortel new -- <command>` does it, so the shell is still there when it exits.

```sh
wortel split                              # a shell to the right
wortel split down -- npm run dev          # a dev server under the terminal
wortel split --session "Site build" -- tail -f build.log
```

Meant for an agent as much as for you: it can put a dev server, a test watcher
or a log beside itself while you are typing to it. So **nothing moves**. The
keyboard stays where it is, the selected session stays selected, and no window
comes forward. In the session on screen the split appears beside what you are
doing. In a session that isn't on screen it is there when you next select it,
and its shell starts at once either way, so the command is running whether or
not anyone is looking. If a split is zoomed (⇧⌘↩), it stays zoomed and the new
one waits behind it.

The split always goes beside the session's main row of tabs, wherever the
command was run, so two of them in a row give three columns. `--session` names
another session, by id or name as [below](#naming-a-session); without it the
command means the session it was run in.

It prints nothing and exits 0. It exits 1, with one line saying why, when the
session's worktree is still being made, when its main terminal is too small
to halve (what ⌘D beeps at), or when the command could not be typed into the
new shell. A command is refused with exit status 2
for the two reasons `new` refuses one: longer than 1024 bytes, or a control
character in it.

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

For an agent, `working`, `needs-you`, `finished` and `failed` are what the
agent itself reports. One that reports nothing (Gemini CLI, goose, aider, or
an old version of one that does) reads as `idle` whatever it is doing.

`--json` prints the same as an array of objects with the fields `id`, `name`,
`folder`, `directory`, `branch`, `worktree`, `agent`, `state`, `selected` and
`caller`. A field with nothing to say is left out rather than `null`. The field
names are a contract: new ones may be added, none will be renamed.

### Naming a session

Wherever a command takes `<session>` (and `--session` on `rename`, `notify`,
`mark` and `remind`) you can give:

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

A `send` to a session that was just made with a command (`wortel new --
claude`) waits for that command's program to have its interface up, so the
text arrives as one paste. It gives up after five seconds, typing nothing.
With `--enter`, the Return lands on whatever the program shows first, which
for an agent is sometimes a question (trust this folder, install an update)
rather than its prompt. When that matters, `wait --idle` and `read` first.

A session whose agent has been idle for an hour may have had it put to sleep.
`list` still names the agent, and selecting the session brings it back. `send`
to such a session types nothing (the text is for the agent, and would land in
the bare shell): it starts the resume and fails with a message saying so. Send
again a few seconds later.

### `wortel wait <session> [--for <text> [--from-start]] [--idle] [--exit] [--timeout <dur>]`

Waits until something happens in a session, then exits 0:

- `--for <text>`: the text appears. It's matched against the plain text, so
  colours and bold can't split it, and it counts only when it's **new**: text
  already on the screen or in the scrollback when the wait starts doesn't end
  it. `--from-start` counts what's already there too.
- `--idle`: the agent in it has finished its turn or is waiting on you (a
  question, a permission), or a plain shell is back at its prompt. A wait that
  starts right after a `send` waits for the agent to start first, so it can't
  end before the work does. A session nobody has touched is idle at once,
  and so is one whose agent doesn't report its state: for those, wait on
  `--for <text>` instead.
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

`rename`, `notify`, `mark`, `remind` and `split` act on the session they were run in, unless given `--session`. You never pass an id:
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
