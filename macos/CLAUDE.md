# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
the **macOS app** in this monorepo. It lives at `macos/`; the landing-page
website lives at `web/` (see the root `CLAUDE.md` for the map). All paths and
commands below are relative to `macos/` — run them from this directory.

## What Wortel is

A minimal, performance-first, fully native macOS terminal. It embeds Ghostty's
real engine (VT parser, Metal renderer, glyph atlas, per-surface IO threads) via
the `GhosttyKit` Swift package — so raw terminal throughput/render/latency are
Ghostty-class by construction. Wortel's own code is only the **app shell**: a
sidebar of named terminal sessions, session persistence, input plumbing, and
menu/keybind wiring. The design goal is "indistinguishable from Ghostty.app,
faster to launch, instant session switch" (see `bench/BENCHMARKS.md`).

Wortel is **zero-config by design**: its entire configuration is the bundled
read-only `Resources/wortel.conf`. The user's real `~/.config/ghostty` is never
loaded.

## Build & run

The `.xcodeproj` is **gitignored and generated** — `project.yml` (XcodeGen) is
the source of truth. After a fresh checkout or any change to `project.yml`:

```sh
xcodegen generate          # regenerate Wortel.xcodeproj from project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Wortel-*/Build/Products/Debug/Wortel.app
```

- Release build (used by benchmarks): `-configuration Release`.
- **Proper signed release:** `./scripts/release.sh` builds Release, signs it
  with your Developer ID (auto-detected), installs to `/Applications`, and
  launches it. This is required for anything that needs a real, registered app
  rather than an ad-hoc Debug build — notably **macOS notifications**: an
  ad-hoc-signed build in DerivedData is *not* registered with the notification
  daemon (`usernoted`), so `UNUserNotificationCenter` reports `granted` and
  accepts posts with no error, but nothing is ever displayed. `--notarize` adds
  hardened runtime + notarization + a `.dmg` for distributing to other Macs
  (needs a `notarytool` keychain profile — see the script footer).
- There is no linter config. For the app itself, "verify" still means building
  and running it — the UI has no test coverage.
- The one test target is `WortelTests`, covering the git panel's logic:

  ```sh
  xcodebuild -project Wortel.xcodeproj -scheme WortelTests test
  ```

  It is **not** hosted by the app — hosting would launch libghostty, Metal and a
  real shell to test pure functions. Instead `project.yml` compiles the
  `Wortel/Git` sources it exercises straight into the bundle, so add a file there
  and it needs listing in both targets. Most of these tests use **git itself as
  the oracle**: they build a repo with `GitFixture` and compare against
  `git log --topo-order` / `git log --graph`, because reproducing those cheaply
  is the whole point of the code under test. See `WortelTests/GitFixture.swift`
  on why its branches are long-lived — a tamer fixture passes against known bugs.
- Performance checks live in `bench/`: `./bench/measure.sh` (cold-launch time +
  memory, Release only), `./bench/gen.sh` (throughput fixtures). Most latency /
  render checks are manual side-by-side vs Ghostty.app — see `bench/BENCHMARKS.md`.

To change terminal behavior, fonts, theme, or keybinds, edit
`Resources/wortel.conf` and rebuild — do **not** add a settings UI or read user
config files.

### Editing `wortel.conf`

Ghostty config has **no trailing/inline comments**: a `#` after a value is
swallowed into the value. Keep every comment on its own line. Config keys are
pinned to Ghostty v1.3.1 (https://ghostty.org/docs/config/reference).

## Architecture

One window. One `GhosttyRuntime`. A list of sessions, each owning exactly one
terminal surface.

**`GhosttyRuntime`** (`Wortel/Ghostty/GhosttyRuntime.swift`) — owns the single
libghostty process state: `ghostty_init`, the config, the `ghostty_app_t`, and
all C runtime callbacks. Callbacks may fire on libghostty's IO/render threads;
each one copies C-pointer data synchronously, then hops to the main thread
(`DispatchQueue.main.async`) for anything touching AppKit. `handleAction`
deliberately returns `false` for tabs, splits, inspector, command palette, etc.
— that "unhandled" is how Wortel enforces "those features don't exist."

**`SurfaceView`** (`Wortel/Ghostty/SurfaceView.swift`, ~750 lines) — the NSView
hosting one surface. Ported from Ghostty.app's `SurfaceView_AppKit.swift` and
trimmed (no splits/drag-drop/inspector/context-menu). libghostty installs its
own IOSurface-backed CALayer and renders from its own thread; this view only
does input forwarding (mouse, keyboard, full `NSTextInputClient` IME dance) and
geometry (size/scale/appearance → libghostty). The keyboard path is subtle —
`keyDown`/`performKeyEquivalent`/`doCommand` coordinate via `lastPerformKeyEvent`
and `keyTextAccumulator` to make IME (Korean/Japanese) and unclaimed command
keys work; preserve the upstream comments when touching it. `GhosttyInput.swift`
holds the NSEvent↔ghostty translation helpers and `KeyboardLayout`.

**`Session`** (`Wortel/Sessions/Session.swift`) — one sidebar entry = one shell
= one surface. The `SurfaceView` is created **lazily** (`ensureSurfaceView`) and
then kept alive until the session closes; switching sessions never rebuilds a
view.

**`SessionManager`** (`Wortel/Sessions/SessionManager.swift`) — `@Observable
@MainActor`, the single source of truth for the session list, `selectedID`, and
inline-rename `editingID`. Setting `selectedID` (from a click *or* a menu
shortcut) is the one code path that lazily spawns the selected surface. On
launch, `restore()` spawns only the selected session's shell before the first
frame, then `warmRemainingSurfaces()` warms the rest one-per-runloop-turn so
launch stays lean. `wire()` connects each surface's callbacks (title/pwd/bell/
close) back to session state.

**`SessionStore`** (`Wortel/Sessions/SessionStore.swift`) — debounced JSON
persistence of the session list (order, names, cwds, selection) to
`~/Library/Application Support/Wortel/sessions.json`. This is *app state*, not
user config — Wortel stays zero-config. Decoder tolerates older files missing
fields. `saveNow` runs synchronously on termination.

**UI shell** (`Wortel/UI/`) — `ContentView` is a SwiftUI `NavigationSplitView`
(sidebar list + terminal detail) hosted inside an AppKit window
(`AppDelegate`). Selection is drawn as a custom accent "pill" rather than
`List(selection:)` because the sidebar never holds keyboard focus (the terminal
does). `TerminalHostViewController` is the key trick: it keeps **every**
session's `SurfaceView` in the hierarchy and switches via
`isHidden`/occlusion/first-responder — never `removeFromSuperview`, never a
rebuild — so switching back is instant with no flash. `updateNSViewController`
fires on any observable change, so `show()` early-returns when already showing
the surface (otherwise it would steal focus from the rename field).

**Git panel** (`Wortel/Git/`) — the trailing inspector: a Changes pane (status,
diff, commit box) and a read-only History pane (commit list, graph gutter,
diff), both driven by `GitRepoModel` off the `git` CLI (`GitService`). Its
design is dominated by one rule: **cost must track the window on screen, not the
size of the repo**, because the terminal beside it has to stay smooth on a
monorepo. Four things follow from that, each of which looks like a pointless
detour until you measure it on a large repo (numbers from a 200k–500k-commit
synthetic; `WortelTests` pins all of them):

- **`GitService.log` deliberately does not pass `--topo-order`.** Asking git for
  an ordering where parents follow children makes it walk the entire repo before
  printing a line — ~870ms vs ~20ms — and `--max-count` does not bound it. A
  commit-graph file fixes that, but most repos don't have one. So we take git's
  cheap default order and re-sort the window in `CommitOrder`, which reproduces
  `--topo-order` exactly. Adding the flag back "for correctness" is the trap.
- **`CommitGraph` retires lanes whose parents aren't loaded**, and folds lanes
  waiting on the same commit (git's `|/`). Without the first, lane count grows
  to the bottom of the list (26 lanes in a 1000-commit window); without the
  second, twenty branches off one commit draw twenty columns where git draws
  five.
- **Paging freezes what's on screen.** `CommitOrder.topological(_:settled:)`
  re-sorts only new commits; sorting the grown window wholesale is more faithful
  to git but moves rows the reader is looking at.
- **Parsing happens off the main actor, and diffs are capped** (`DiffParser`).
  `GitRepoModel` is `@MainActor`, so parsing a regenerated lock file's 51MB
  patch there froze the app — terminal included — for 1.2s.

`refresh()` runs one `git status` at a time (it's a full worktree walk; the
FSEvents watcher fires on every write, and bursts used to stack scans), and
watches `# branch.oid` so a commit made **in the terminal** — the normal way —
reloads History.

**Menus** (`Wortel/MainMenu.swift`) — built programmatically and kept small
because AppKit scans key equivalents on every keypress. The menu is
**authoritative** for key equivalents, and this interacts with `wortel.conf`
keybinds: e.g. "Select All" is bound to ⌘⇧A precisely so that ⌘A is freed for
the `wortel.conf` keybind that clears the input line. When adding/moving a
keybind, check both files.

## Conventions & constraints

- **Main-thread only** for everything Wortel owns; only libghostty callbacks
  cross threads, and they marshal to main immediately.
- Deliberately **feature-minimal**: no tabs, no splits, no inspector, no
  settings UI, no user-config loading. Returning `false`/doing nothing for those
  is intentional, not a gap to fill.
- Resources are shipped as **folder references** (`Resources/terminfo`,
  `Resources/ghostty`) landing in `Contents/Resources/`; the Zig core locates
  them via the `terminfo/78/xterm-ghostty` sentinel. Don't restructure those
  paths.
- `GhosttyRuntime` init pins config loading to the bundle only — never
  `ghostty_config_load_default_files` (leaks the user's real config) or
  `load_cli_args` (reads Xcode debug flags on macOS).
