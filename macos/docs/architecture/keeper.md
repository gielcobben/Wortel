# The keeper

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

`wortel-keeper` (`WortelKeeper/main.swift`, `Wortel/Keeper/`) is the process
that holds the ptys, so shells stop being the app's children. Quitting Wortel
closes a window; the work carries on, and the next launch attaches to it.

This is an orientation. The reasoning lives in the source, in the comments at
the top of `KeeperProtocol.swift`, `KeeperServer.swift`, `KeeperConnection.swift`,
`KeeperClient.swift` and `ReplayBuffer.swift`. Read those before changing
anything here, and keep them true.

## What it is

Small and dumb, on purpose. It forks what it is told to fork and hands out
descriptors. It knows nothing about terminals, sessions, git or rendering.
Every decision about what to run is made by the app and arrives as data
(`KeeperSpawnPlan`). It is the one process that has to outlive everything else,
and the way it earns that is by having almost no reason to change.

It is started by the app on demand, in its own session (`setsid`), and it ends
by itself 30 seconds after it holds nothing and nobody is connected.

## The one invariant

**Only one process reads a pty at a time.** Two readers would split the bytes
between them, and the corruption would be intermittent.

- Attached: the app reads the descriptor directly, as it would a local pty. The
  keeper passed it over the socket (`SCM_RIGHTS`) and its own read is suspended.
  Forwarding bytes through the socket instead would put a copy and a wakeup on
  the hottest path in a terminal.
- Detached: the keeper drains the pty into a bounded `ReplayBuffer`, so a shell
  never blocks on a full pty.
- The handover is `attach`, and the connection closing. The app never sends
  `detach`: quitting, crashing and `kill -9` all look the same from the keeper,
  and all three have to work.

## Things that look wrong and aren't

- **The connection is held open for the whole run.** Closing it tells the keeper
  the app has gone. After a failed request the socket is left open but unused,
  for the same reason: replies carry no request id, so a late one could hand an
  `attach` another session's pty.
- **A keeper from an older build is normal.** Updating the app does not restart
  the keeper. One that speaks another protocol is replaced, which costs its
  shells. One from another build with the same protocol is kept while it holds
  sessions: a stale binary is never worth a live shell. This also means a fix
  made in the keeper reaches a user only when their keeper next restarts.
- **A keeper holding sessions is killed only when it answers and names another
  protocol.** A ping that timed out says nothing about the sessions behind it.
  One from another build that holds nothing is replaced, since that costs no
  shell.
- **The replay buffer drops from the front, and is not scrollback.** What you
  want after being away is how it ended. It only fills while detached. The
  terminal modes a program set in the bytes that were dropped are read on the
  way out and put back in front of the replay (`docs/terminal-modes.md`).
- **The replay is never fed from the main thread.** See `../docs/incidents.md`,
  2026-10-07.
- **The signal sources in `main.swift` are kept in an array.** Release them and
  the process ignores every signal short of SIGKILL.

## What it cannot protect against

Something outside killing the keeper. macOS can end it from the Dock ("Stop
Running in Background", or a Force Quit of an app that shares its coalition),
and nothing the keeper does can prevent that. Running it under launchd and as
its own background app were both tried and both reverted (`../docs/decisions.md`).

The answer is recovery: the app watches the keeper's pid, restarts dead
terminals in place and types each agent's exact resume. `scripts/try-keeper-loss.sh`
tests that against a throwaway copy.

## Reading its life back

Both ends log at default level, so it is on disk days later:

```sh
/usr/bin/log show --last 1d --predicate 'subsystem == "com.gielcobben.Wortel" && category == "keeper"'
```

A session's shell is a child of `/usr/bin/login`, which is a child of the
keeper. macOS `pgrep` hides its own ancestors; use `pgrep -a`.
