---
name: test-copy
description: Run a throwaway copy of the Wortel app beside the real one, with its own bundle id, data folder, keeper and socket, and drive it from the command line. Use to test a change yourself (sessions, keeper, attention, resume, the wortel command) without touching the person's running app or their sessions.
---

# A throwaway copy of Wortel

For tests of your own. It is never the answer to "run the build" (that is the
`run-build` skill). `macos/scripts/try-keeper-loss.sh` is a working example of
making, launching, killing and cleaning up a copy.

## Why `WORTEL_DATA_DIR` alone is not enough

`WORTEL_DATA_DIR` gives a launch its own sessions, keeper and `wortel` socket.
UserDefaults are still shared, because they go by bundle id, and a first launch
prunes folder order and pinned sessions there. So the
copy gets its own bundle id as well.

## Make it

```sh
SRC=<path to a built Wortel.app>          # see the run-build skill, step 3
COPY="$HOME/.wt/WortelTest.app"           # any short path
DATA="$HOME/.wt/data"
mkdir -p "$DATA"
cp -Rc "$SRC" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.test" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY"
open -g -n --env WORTEL_DATA_DIR="$DATA" --env DO_NOT_TRACK=1 "$COPY"
```

- **Keep the data path short.** Sockets live in it and a socket path is at most
  104 bytes. A scratch directory deep under `/private/tmp` is too long.
- **`DO_NOT_TRACK=1`**, or the copy is counted as a new install.
- To start from a known state, write `sessions.json` into the data folder
  before launching (a session with `runningAgent` set gets its resume typed).

## Drive it without touching the UI

The copy carries its own command. **`WORTEL_DATA_DIR` is what points a command
at the copy, not which binary you run.** Without it either binary talks to the
person's real app, and a `send` types into their real sessions. Set it on
every call:

```sh
W="$COPY/Contents/Resources/bin/wortel"
WORTEL_DATA_DIR="$DATA" "$W" new --cwd /tmp -- <command>
WORTEL_DATA_DIR="$DATA" "$W" list --json
WORTEL_DATA_DIR="$DATA" "$W" send <session> "text" --enter
WORTEL_DATA_DIR="$DATA" "$W" wait <session> --idle
WORTEL_DATA_DIR="$DATA" "$W" read <session>
```

`send` without `--enter` leaves the text in the program's input box.

To fake a signal from a program, write to the tty of the process in the session
(`ps -o tty= -p <pid>`, then `printf` to `/dev/ttysNNN`): screen repaints, an
OSC 0 title, an OSC 9. To read what the app decided, stream its log by pid,
started after launch:

```sh
/usr/bin/log stream --level debug --predicate 'processID == <pid> AND category == "agent-status"'
```

## Before you believe a failure

- **Is the screen locked?** No display means no surface, nothing reads the
  ptys, and nothing typed ever runs. Not a bug.
- **Focus moves.** Anything about "is the person looking at it" depends on which
  app is frontmost when the event lands. Check that at the moment it matters,
  and expect other things on the machine to take focus mid-run.
- **Away detection.** A minute without input counts as away, which changes what
  an attention signal does.
- **Agents rename themselves.** Pi's process becomes plain `pi` shortly after
  start; match the command, not the arguments you launched it with.
- `status` is read-only in zsh. Call the variable something else.

## Put it away

```sh
COPY="$HOME/.wt/WortelTest.app"
kill <pid of the copy>                    # by pid, never by name
sleep 1
# Every pid under $1, and $1. From macos/scripts/try-keeper-loss.sh.
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
for k in $(pgrep -f "$COPY/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k); done
rm -rf "$HOME/.wt"
```

The copy's keeper outlives it by design, exactly like the real one, so quitting
the copy is not the end of it. The loop ends the keeper and every shell under
it before the folder goes. Run the block as one command.
