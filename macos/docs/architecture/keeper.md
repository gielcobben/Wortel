# The keeper

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

`wortel-keeper` (`WortelKeeper/`, with `Wortel/Keeper/` shared with the app)
is the process that holds the ptys **and each session's terminal**, so shells
stop being the app's children and their terminals stop being the app's to
lose. Quitting Wortel closes a window; the work carries on, and the next
launch shows every terminal exactly as it is.

This is an orientation. The reasoning lives in the source, in the comments at
the top of `KeeperProtocol.swift`, `KeeperServer.swift`, `KeeperTerminal.swift`,
`KeeperOutputChannel.swift`, `KeeperConnection.swift` and `KeptTerminalFeed.swift`.
Read those before changing anything here, and keep them true.

## What it is

It forks what it is told to fork. Every decision about what to run is made by
the app and arrives as data (`KeeperSpawnPlan`). It knows nothing about
sessions, git or rendering.

For each session it holds a **terminal**: libghostty-vt (`KeeperTerminal`), a
Ghostty terminal with no renderer, built from the same Ghostty commit as the
app's (`scripts/build-ghostty.sh`). It reads the pty itself, always, and every
byte goes into that terminal, at the size the pty has. That terminal is the
session's record. The app's surface is a copy of it.

It is started by the app on demand, in its own session (`setsid`), and it ends
by itself 30 seconds after it holds nothing and nobody is connected.

## The channel

An app that attaches to a session (`KeeperCommand.terminal`, opening it if it
does not exist) gets two descriptors: the session's **output channel** and the
pty.

- The channel is frames (`KeeperChannel`): a **snapshot** of the keeper's
  terminal, then every **output** read of the pty after it. The cut is made on
  the session's read queue, between two reads, so nothing is lost or seen twice.
  A surface shown again after it was dropped asks for another snapshot down the
  same channel (`resync`) and goes on from there.
- The pty is for typing into, and for asking who is in the foreground. The app
  never reads it: **the keeper is every pty's one reader.**

The app restores its surface from the snapshot with Wortel's Ghostty patch
(`ghostty_surface_restore_snapshot`, `GhosttyKit/Patches/0100`), then feeds it
the output (`KeptTerminalFeed`). Nothing is replayed, re-wrapped or repainted:
the snapshot is the terminal, both screens, all of the scrollback, the modes,
and whatever sequence the program was in the middle of.

## Rules that look wrong and aren't

- **The keeper answers the program; the app never does.** Cursor position,
  device attributes, colours, light or dark, sizes, and the agent status
  question (`OSC 7501 ; ?`): libghostty-vt's answers (`KeeperTerminal`), with
  the app open or not, in the order they were asked. The order is part of the
  answer: Claude Code takes a DA1 answer that comes before its status answer
  as "no", and when the app answered that question it came second
  (`../agent-signals.md`). The surface is fed with
  `ghostty_surface_write_buffer_replay` and told `ghostty_surface_set_responds(false)`,
  so nothing is answered twice. The app tells the keeper its colours and light
  or dark (`appearance`).
- **A size is the keeper's to apply.** The surface's grid goes to the keeper
  (`resize`), which sets the pty's size and resizes its terminal on the read
  queue, between two reads. A dropped terminal out of sight follows the window
  the same way (`SurfaceView.followWindowWithoutSurface`). A resize to the size
  it has is dropped.
- **Nothing in the read loop waits on the app.** The channel is non-blocking and
  its queue bounded (`KeeperOutputChannel.limit`, 32 MB); an app that falls that
  far behind loses its channel, never the shell its output. Answers to the
  program are written off the read queue.
- **What Wortel writes into a terminal goes through the keeper** (`inject`: the
  modes taken back from an agent it ends), so the two copies stay one.
- **What a program writes while no app is attached is kept as well**
  (`OutputTail`, 512 KB), and taken by the next app that attaches, for what
  the program said about itself meanwhile (`ProgramStatusWatch`). Only that:
  a report the app heard before it quit, heard again, would be raised twice
  (`verify-agent-status.py`, "relaunch: still blocked"). It is never written
  into a terminal.
- **The connection is held open for the whole run.** Closing it tells the keeper
  the app has gone, and the keeper lets go of that app's channels. Quitting,
  crashing and `kill -9` all look the same, and all three keep every terminal.
- **A quiet terminal's scrollback is compressed** (every 15 s look that finds it
  unchanged); it is decompressed when touched. Measured 108 MB to 23 MB for ten
  full scrollbacks.
- **A keeper from an older build is kept while it holds sessions,** if it speaks
  the same protocol: a stale binary is never worth a live shell. One that speaks
  another protocol is replaced, which ends its shells. Protocol 2 (2026-11)
  replaced every protocol 1 keeper once, at that update.
- **The signal sources in `main.swift` are kept in an array.** Release them and
  the process ignores every signal short of SIGKILL.

## What it cannot protect against

Something outside killing the keeper. macOS can end it from the Dock ("Stop
Running in Background", or a Force Quit of an app that shares its coalition),
and nothing the keeper does can prevent that. Running it under launchd and as
its own background app were both tried and both reverted (`../docs/decisions.md`).
Its terminals go with it: they live in its memory.

The answer is recovery: the app watches the keeper's pid, restarts dead
terminals in place and types each agent's exact resume. `scripts/try-keeper-loss.sh`
tests that against a throwaway copy.

## Testing it

- `WortelTests`: `KeeperTerminalTests` (the terminal, its snapshot, its
  answers), `KeeperTerminalProtocolTests` (the cut is exact under a flood, a
  stalled app never stalls a shell), `KeeperChannelReaderTests`, `KeeperTests`.
- `scripts/try-app-crash.sh`: a crash, a quit and a dropped terminal, each with
  an agent drawing in place, read back exactly.
- `KeeperTerminalThroughputTests` prints what the keeper adds per MB and per
  keystroke; `bench/BENCHMARKS.md` has the numbers.

## Reading its life back

Both ends log at default level, so it is on disk days later:

```sh
/usr/bin/log show --last 1d --predicate 'subsystem == "com.gielcobben.Wortel" && category == "keeper"'
```

A session's shell is a child of `/usr/bin/login`, which is a child of the
keeper. macOS `pgrep` hides its own ancestors; use `pgrep -a`.
