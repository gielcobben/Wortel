# macos/: the app

For coding agents working on the macOS app. The repo-wide rules are in the root
`AGENTS.md` and still apply; this file adds what is specific to the app. All
paths and commands below are relative to `macos/`. Run them from this directory.

This file is short on purpose. The architecture record is in `docs/`, one file
per area, and the table below says which to read before touching what. Read the
one you need. Don't read them all.

## What Wortel is

A minimal, performance-first, fully native macOS terminal. It embeds Ghostty's
real engine (VT parser, Metal renderer, glyph atlas, per-surface IO threads) via
`GhosttyKit`, built here from source (`scripts/build-ghostty.sh`), so raw
terminal throughput/render/latency are Ghostty-class by construction. Each
session's terminal lives in the keeper (`docs/architecture/keeper.md`); the
app's surface is a copy of it. Wortel's own code is only the **app shell**: a
sidebar of named terminal sessions, session persistence, input plumbing, and
menu/keybind wiring. The design goal is "indistinguishable from Ghostty.app,
faster to launch, instant session switch" (see `bench/BENCHMARKS.md`).

The terminal's entire configuration is the bundled read-only
`Resources/wortel.conf`. The user's real `~/.config/ghostty` is never loaded.
What a person can change is a handful of switches in the Settings window (⌘,).

## Commands

```sh
scripts/build-ghostty.sh     # Ghostty from source; first, once per pinned commit
xcodegen generate            # after a fresh checkout or any change to project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
xcodebuild -project Wortel.xcodeproj -scheme WortelTests test    # about 85s
../scripts/check.sh macos    # generate, then the same tests, in one command
scripts/check-terminals.sh   # every terminal test, in throwaway copies, about 7 minutes
```

- The `.xcodeproj` is generated and gitignored. `project.yml` is the source of
  truth.
- `WortelTests` is not hosted by the app. `project.yml` lists each source it
  compiles, so **a new tested file is listed in both targets**.
- There is no linter and no UI test. For the app itself, "verify" means building
  it and using it.
- Don't `clean` a Debug build to fix something. It has cost a link failure on
  the YAML grammar's scanner, and a plain rebuild recovers. (A release does run
  `clean build`, against the pinned packages.)
- Everything else about building, signing, pinned packages, the test target and
  `wortel.conf` is in `docs/building.md`.

## Read before you touch

| You are changing | Read first |
| --- | --- |
| `Wortel/Ghostty/` | `docs/architecture/runtime-and-surface.md`, and `docs/terminal-modes.md` or `docs/accessibility.md` for those parts. Run `scripts/check-terminals.sh` before it is merged |
| Light and dark: a theme, a layer colour, what a program is told | `docs/appearance.md`. Run `scripts/try-appearance.sh` |
| `Wortel/Sessions/` | `docs/architecture/sessions.md`, `docs/session-naming.md` |
| Busy state, dots, notifications | `docs/agent-signals.md`. Run `scripts/verify-agent-status.py` before it ships |
| `Wortel/UI/`, the sidebar | `docs/architecture/window-and-sidebar.md`, and `../DESIGN.md` for anything that is drawn |
| `Wortel/Settings/`, a new setting | `docs/architecture/settings.md` |
| Tabs, the side column, the bottom strip, `Wortel/Browser/` | `docs/architecture/workspace-tabs.md` |
| Splits of the main area: `SplitLayout`, `SplitTreeView`, `SplitPane.swift`, a tab drag's landing | `docs/architecture/workspace-tabs.md` ("Splits of the main area"). Run `scripts/try-splits.sh` |
| `Wortel/Git/` | `docs/architecture/git-panel.md` |
| Anything about worktrees | `docs/worktrees.md` (the model), `docs/architecture/worktrees.md` (the code) |
| `Wortel/Files/`, `Wortel/Preview/`, `Wortel/Markdown/` | `docs/architecture/files-and-previews.md`, `docs/file-preview.md` |
| `Wortel/Keeper/`, `WortelKeeper/` | `docs/architecture/keeper.md`, `../docs/incidents.md` |
| `Wortel/CLI/`, `WortelCLI/` | `docs/architecture/command-menus-hotkey.md`, `docs/cli.md` (design), `docs/wortel-command.md` (the user's guide) |
| `Wortel/Processes/` | `docs/running-processes.md`. Run `scripts/verify-running-jobs.py` before it ships |
| `Wortel/Telemetry/` | `docs/telemetry.md` |
| `MainMenu.swift`, `GlobalHotkey.swift`, any shortcut | `docs/architecture/command-menus-hotkey.md`, `docs/shortcuts.md` |
| `Resources/wortel.conf` | `docs/building.md` (no inline comments) |
| `Resources/ghostty/shell-integration/` | `docs/debugging.md` (three copies, kept in step) |
| `Wortel/InheritedEnvironment.swift` | `docs/inherited-launcher-environment.md` |
| `Grammars/`, a new language | `Grammars/README.md` |
| Launch time, throughput | `bench/BENCHMARKS.md` |
| Something that doesn't behave | `docs/debugging.md` |

Before changing how something works, look it up in `../docs/decisions.md`. A lot
of what looks unfinished here was tried, measured and taken out.

## Working on the app

- **Building is always safe. Quitting Wortel is not.** Whoever asked is often
  typing to you from inside the app you are about to replace. Don't quit, kill
  or relaunch a running Wortel unless asked. "Run the new build" is that ask:
  it means replace the running app, and the `run-build` skill has the steps.
- **Don't drive the app or screenshot the screen to verify a change.** Build it,
  say what to look at, and let the person try it. Synthetic keystrokes have
  landed in other apps and in a running agent.
- **For a test of your own, use a throwaway copy**, never the real app and its
  data: the `test-copy` skill. A second Wortel on the same data folder, from
  any bundle, only brings the first one forward (`InstanceLock`).
- **A Debug build is its own app unless the Mac opted in.** Without
  `~/Library/Application Support/Wortel/debug-builds-share-this-folder` it uses
  `Wortel Dev` and the bundle id `com.gielcobben.Wortel.dev`. With it (the
  owner's Mac), a Debug build and the installed app share one data folder and
  one keeper: an older build opens a newer `sessions.json`, ignores the fields
  it doesn't know and saves it back without them, so install the new version
  before launching the installed app, not after. Never create or remove that
  file yourself (`docs/building.md`).
- **Notifications need a signed build in `/Applications`.** An ad-hoc Debug
  build is told `granted`, posts without error, and nothing is shown.
- **Test with real agents and real processes when the change is about them.**
  Fixtures hold the shapes somebody already thought of, and every bug in resume
  and in running processes has been a shape nobody had.
- Releasing is the `release` skill. Publishing is never done unasked.

Skills are in `../.agents/skills/` (Claude Code reads them through
`../.claude/skills`): `run-build`, `test-copy`, `release`, `release-note`,
`update-ghostty`.

## Conventions & constraints

- **No em-dashes in any string a user reads** — UI copy, notifications, the
  model prompts and what they are told to generate. Comments and commit
  messages are exempt. See the root `CLAUDE.md`.
- **Main-thread only** for everything Wortel owns; only libghostty callbacks
  cross threads, and they marshal to main immediately. `TelemetryClient` is the
  one deliberate exception: it is an actor, because it is the only thing here
  that touches the network and must never make the terminal wait. `SerialGate`
  (`GitService.backgroundStatus`) is the other: a queue that lets background
  `git status` scans run one at a time app-wide, holding no state of Wortel's.
  `SurfaceAccessibilityWatch` is the third: the pty's output handler and
  libghostty's scrollbar action call it on their own threads, because a hop to
  main per read is what a terminal under `cat` can't afford. It holds two
  values behind a lock and throttles to one main-thread hop a quarter second.
  The fourth is computation fanned out over the cores for one call: ⌘P's
  `FileMatch.rank` and `FileListing.walk` share a result box (and the walk a
  lock) between their workers, and keep nothing once the call returns.
- **Nothing about the user's work leaves the machine.** Wortel reports anonymous
  feature usage (`Wortel/Telemetry/`, opt-out, `docs/telemetry.md`) and that is
  the whole of it. No case in `TelemetryEvent` takes a `String`, which is what
  makes "could this leak a repo name" a question the compiler answers rather
  than one you have to audit. Adding a `String` parameter to any event is the
  change that breaks the promise on wortel.sh/privacy; if a question needs a
  value that is not a small closed set, the answer is a bucket or no event.
- Deliberately **feature-minimal**: a short Settings window (see
  `docs/architecture/settings.md` before adding a row), no user-config
  loading. The
  *terminal* has no tabs and no splits of its own: sessions are Wortel's tabs,
  and libghostty's tab/split actions still return `false`. The tabs, the side
  column, the strip and the splits of the main area are all Wortel's (see
  **Tabs and the workspace**), not libghostty's. Splits are on the branch
  `flexible-panes`, not released (`../docs/decisions.md`, 2026-11-26).
- Resources are shipped as **folder references** (`Resources/terminfo`,
  `Resources/ghostty`) landing in `Contents/Resources/`; the Zig core locates
  them via the `terminfo/78/xterm-ghostty` sentinel. Don't restructure those
  paths.
- `GHOSTTY_BIN_DIR` points at `Resources/ghostty/bin`, which holds one small
  `sh` script named `ghostty` that answers `+ssh-cache` (the only `ghostty`
  command the integration runs). Without it the "terminfo already installed on
  this host?" check always failed, so every `ssh` reinstalled it, printed a
  setup line and left a `/tmp/ghostty-ssh-*` directory. The cache is
  `ssh-terminfo-hosts` in the data folder, 30-day entries, each with a
  checksum of the bundled terminfo, so a new entry reaches hosts already set
  up (the integration's remote step always runs `tic`). Keeper-spawned
  shells only: the exec fallback gets whatever libghostty sets.
- `GhosttyRuntime` init pins config loading to the bundle only — never
  `ghostty_config_load_default_files` (leaks the user's real config) or
  `load_cli_args` (reads Xcode debug flags on macOS).
