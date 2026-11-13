---
name: run-build
description: Build the Wortel macOS app and put the new build in front of the person. Resolves the right bundle, replaces the running app without losing its sessions, and checks that a window came up. Use after a change in macos/ when asked to run, launch, relaunch, try or replace the build.
---

# Run the build

All commands run from `macos/`.

## 1. Build

```sh
xcodegen generate     # only after a fresh checkout or a change to project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
```

Never `clean`. If the link fails on a tree-sitter scanner symbol, run the same
build again.

## 2. Find the bundle you just built

```sh
APP="$(xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Wortel.app"
```

Do not glob DerivedData. There are usually several `Wortel-<hash>` folders, most
of them stale, and `open` takes every path the glob gives it.

## 3. Were you asked to run it?

- **Asked only to make a change:** stop here. Say it built, give the path, and
  say what to look at. Building is always safe; replacing the app is theirs to
  ask for.
- **Asked to run, launch, relaunch or replace it:** go on. That request is the
  permission to quit the running app. Don't start a copy beside it instead: a
  second launch of the same bundle only brings the first one forward
  (`InstanceLock`), and a copy with its own data is not what was asked.

Once someone has asked for a relaunch in a build-and-test loop, it holds for
the rest of that loop.

## 4. Swap the running app

The person is usually typing to you from inside Wortel. Quitting it does not
end your shell, because the keeper holds it, and the session comes back attached
in the new build. Run the swap detached all the same, so nothing depends on the
app that is going away:

```sh
cat > "${TMPDIR:-/tmp}/wortel-swap.sh" <<'EOF'
#!/bin/zsh
new=$1
pid=$(pgrep -x Wortel | head -1)
if [[ -n $pid ]]; then
  running=$(ps -o comm= -p "$pid")
  running=${running%/Contents/MacOS/Wortel}
  osascript -e "tell application \"$running\" to quit"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
fi
open "$new"
EOF
nohup zsh "${TMPDIR:-/tmp}/wortel-swap.sh" "$APP" >/dev/null 2>&1 &!
```

Quit by the running bundle's path, never by name: the installed app, a Debug
build and a test copy are all called Wortel.

## 5. Check a window came up

A live pid proves nothing. An exception during launch is swallowed and the app
runs on with no window. This reads window metadata only:

```sh
sleep 3; swift - <<'EOF'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let wins = all.filter {
  ($0[kCGWindowOwnerName as String] as? String) == "Wortel" && ($0[kCGWindowLayer as String] as? Int) == 0
}
for w in wins {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print("window", b["Width"] ?? "?", "x", b["Height"] ?? "?", "pid", w[kCGWindowOwnerPID as String] ?? "?")
}
print(wins.isEmpty ? "NO WINDOW" : "ok")
EOF
```

`NO WINDOW` with a live process: `sample <pid> 1` and look for
`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`. A locked screen also
gives no surfaces (`macos/docs/debugging.md`).

## 6. Hand it over

Say what changed and what to try. Don't drive the app with synthetic keys and
don't screenshot the screen to prove it works.

## Things this build cannot show

- **Notifications.** An ad-hoc Debug build is never shown one. That needs
  `./scripts/release.sh`, which signs, installs to `/Applications` and
  relaunches. Ask first: it replaces the installed app.
- **The installed app is a different app.** The Dock and Spotlight open
  `/Applications/Wortel.app`, so a quit and relaunch from there tests the old
  build. And an older build saves `sessions.json` back without the fields it
  doesn't know, so going back to the installed app after working in a newer
  Debug build can drop tab layout. Install the new version first.
