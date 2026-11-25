---
name: wortel
description: Use when running inside the Wortel terminal ($WORTEL_SESSION_ID is set) and the work calls for Wortel itself - moving this session and its conversation to another project folder (wortel cd), closing this session or removing, deleting or cleaning up its worktree (wortel close), starting another session or agent, reading, sending to or waiting on another session, raising attention, colouring or renaming a session, or setting a reminder.
---

<!-- Written by Wortel and kept up to date by it. Edit it and Wortel leaves it alone; delete it and it stays deleted. -->

# Wortel

You are running in a session of Wortel, a macOS terminal. Each session is a row
in its sidebar with its own shell, and the `wortel` command (on your PATH)
talks to the app. Commands act on your own session unless given another one.
`wortel --help` lists them all.

## Move this session to another project

When the work turns to a project in another folder than the one this session
started in, offer to move. Once the person agrees:

```sh
wortel cd ~/Developer/opmaak
```

Then finish your reply and start nothing else. When your turn ends, Wortel
quits you, `cd`s the shell there and resumes this same conversation, so the
person sees that project's git and you get its own CLAUDE.md and settings.
Anything you started that is still running stops. Never suggest `/add-dir` or a
new session instead of a move.

## Close this session, and its worktree with it

When the person asks to close this session, or to remove, delete or clean up
the worktree you are working in, don't run `git worktree remove` or
`git branch -d`, and don't tell them to. Run:

```sh
wortel close
```

Then finish your reply and start nothing else. When your turn ends, Wortel
closes the session and moves its worktree to the Trash, with the branch if
nothing on it is unique. If there are uncommitted or untracked files, Wortel
asks the person in the app first; if they keep it, the session is archived.
Before you run it, say anything worth knowing that would go: work not yet
copied or committed somewhere else.

## Start and drive other sessions

```sh
wortel new --cwd ~/Developer/site --name "Site build" -- claude   # a session running a command
wortel new --worktree --name "Try idea"                             # on a new branch, in its own worktree
wortel list                                                         # every open session: id, name, state, agent
wortel send "Site build" "fix the failing test" --enter             # type a prompt into it
wortel wait "Site build" --idle --timeout 10m                       # until it has finished its turn
wortel read "Site build" --lines 80                                 # what it says
```

A session is named by its id (the short one `list` prints) or its name. Use
this when the person asks for work in parallel, or to hand a task to another
agent; tell them which sessions you started.

## Tell the person something

```sh
wortel notify "Build done" "all 1474 tests pass"   # a dot on this row and a notification
wortel remind 1h                                    # bring this session back to them later
wortel mark green                                   # colour this row: red, orange, yellow, green, blue, purple, grey, none
wortel rename "Header redesign"                     # name this row
```

Notify only for something the person is waiting on, not for every step.
