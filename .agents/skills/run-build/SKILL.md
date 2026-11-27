---
name: run-build
description: Build the Wortel macOS app and put the new build in front of the person. Resolves the right bundle, replaces the running app without losing its sessions, and checks that a window came up. Use after a change in macos/ when asked to run, launch, relaunch, try or replace the build.
---

# Run the build

All commands run from `macos/`. Shell variables do not survive from one command
to the next, so each block below sets what it uses.

## 1. Build

```sh
xcodegen generate     # only after a fresh checkout or a change to project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
```

Don't add `clean`. If the link fails on a tree-sitter scanner symbol, run the
same build again.

**Build `main`, or a branch rebased on today's `main`**, for the owner's daily
app. Never a branch that is behind `main`: where Debug builds share the usual
data folder, an older build saves `sessions.json` back without the fields it
doesn't know, and the owner's layout goes with them. Rebase first
(`git fetch origin main && git rebase origin/main`).

**Which Wortel a Debug build is.** On a Mac where
`~/Library/Application Support/Wortel/debug-builds-share-this-folder` exists,
a Debug build is the daily Wortel: the usual data folder and the bundle id
`com.gielcobben.Wortel`. Anywhere else (a fresh clone, a contributor's Mac) it
is its own app: `~/Library/Application Support/Wortel Dev` and
`com.gielcobben.Wortel.dev`, and it never touches the installed Wortel. The
blocks below find the running copy in whichever folder the build will use.
Never create that file yourself: it is the owner's choice, made once per Mac.
A build made before it was created or removed keeps the old bundle id until
the next build.

## 2. Were you asked to run it?

- **Asked only to make a change:** stop here. Say it built, give the path of the
  bundle (step 3 prints it), and say what to look at. Building is always safe;
  replacing the app is theirs to ask for.
- **Asked to run, launch, relaunch or replace it:** go on. That request is the
  permission to quit the running app. Don't start a copy beside it instead: a
  second Wortel on the same data folder, from any bundle, only brings the first
  one forward and exits (`InstanceLock`), and a copy with its own data is not
  what was asked.

Once someone has asked for a relaunch in a build-and-test loop, it holds for
the rest of that loop.

## 3. Swap the running app

The person is usually typing to you from inside Wortel. Quitting it does not
end your shell, because the keeper holds it, and the session comes back attached
in the new build. Run the swap detached all the same, so nothing depends on the
app that is going away.

One command, start to finish:

```sh
APP="$(xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Wortel.app"
echo "built: $APP"

cat > "${TMPDIR:-/tmp}/wortel-swap.sh" <<'EOF'
#!/bin/zsh
new=$1
[[ -d $new ]] || { print -u2 "no app at: $new"; exit 1 }
# The Wortel that owns the data folder writes its pid here: the usual folder
# where this Mac shares it with Debug builds, a Debug build's own otherwise.
base="$HOME/Library/Application Support"
lock="$base/Wortel Dev/instance.lock"
[[ -e "$base/Wortel/debug-builds-share-this-folder" ]] && lock="$base/Wortel/instance.lock"
pid=$(cat "$lock" 2>/dev/null)
if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
  running=$(ps -o comm= -p "$pid")
  running=${running%/Contents/MacOS/Wortel}
  osascript -e "tell application \"$running\" to quit"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
fi
open "$new"
EOF
[ -d "$APP" ] && { nohup zsh "${TMPDIR:-/tmp}/wortel-swap.sh" "$APP" >/dev/null 2>&1 & disown; }
```

Why it is written this way:

- **Resolve the bundle from the build settings.** Don't glob DerivedData: there
  are usually several `Wortel-<hash>` folders, most of them stale, and `open`
  takes every path a glob gives it.
- **Find the running app through `instance.lock`, not `pgrep`.** On macOS
  `pgrep` leaves out its own ancestors, and when you are inside Wortel, Wortel
  is one: `pgrep -x Wortel` prints nothing, the quit is skipped, and `open` just
  brings the old app forward.
- **Quit by the running bundle's path, never by name.** The installed app, a
  Debug build and a test copy are all called Wortel.
- **The script refuses to quit anything if the new bundle is not there.**

## 4. Check the new build is the one on screen

A live pid proves nothing: an exception during launch is swallowed and the app
runs on with no window. And a window proves nothing if it is the old app's.
This waits for the lock to change hands, then looks for a window owned by that
pid. It reads window metadata only.

```sh
APP="$(xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Wortel.app"
base="$HOME/Library/Application Support"
lock="$base/Wortel Dev/instance.lock"
[ -e "$base/Wortel/debug-builds-share-this-folder" ] && lock="$base/Wortel/instance.lock"
for i in $(seq 1 40); do
  pid=$(cat "$lock" 2>/dev/null)
  [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "$APP/Contents/MacOS/Wortel" ] && break
  sleep 0.5
done
ps -o pid=,comm= -p "$pid"       # must be the bundle you built
sleep 2
WPID=$pid swift - <<'EOF'
import CoreGraphics
import Foundation
let want = Int(ProcessInfo.processInfo.environment["WPID"] ?? "") ?? -1
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let wins = all.filter {
  ($0[kCGWindowOwnerPID as String] as? Int) == want && ($0[kCGWindowLayer as String] as? Int) == 0
}
for w in wins {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print("window", b["Width"] ?? "?", "x", b["Height"] ?? "?")
}
print(wins.isEmpty ? "NO WINDOW for pid \(want)" : "ok, pid \(want)")
EOF
```

`NO WINDOW` with a live process: `sample <pid> 1` and look for
`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`. A locked screen also
gives no surfaces (`macos/docs/debugging.md`).

## 5. Hand it over

Say what changed and what to try. Don't drive the app with synthetic keys and
don't screenshot the screen to prove it works.

## Things this build cannot show

- **Notifications.** An ad-hoc Debug build is never shown one. That needs a
  signed build in `/Applications`, which is `./scripts/release.sh`. Don't run
  that from a shell inside Wortel: its install step quits Wortel by name and
  removes `/Applications/Wortel.app`, the bundle the live keeper is running
  from. Ask the person to run it from another terminal.
- **The installed app is a different app.** The Dock and Spotlight open
  `/Applications/Wortel.app`, so a quit and relaunch from there tests the old
  build. And where Debug builds share the usual folder, an older build saves
  `sessions.json` back without the fields it doesn't know, so going back to
  the installed app after working in a newer Debug build can drop tab layout.
  Install the new version first.
