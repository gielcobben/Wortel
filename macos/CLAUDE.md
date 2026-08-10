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
- The one test target is `WortelTests`, covering the git panel's logic and the
  persisted-session format:

  ```sh
  xcodebuild -project Wortel.xcodeproj -scheme WortelTests test
  ```

  It is **not** hosted by the app — hosting would launch libghostty, Metal and a
  real shell to test pure functions. Instead `project.yml` lists the individual
  sources it exercises (`Wortel/Git/*`, plus `SessionStore.swift` and
  `SessionName.swift`) and compiles them straight into the bundle, so adding a
  file needs it listed in both targets. The bar for a source being here is that
  it's testable *without* the app shell — which is also a reason to keep
  migration decisions out of types that would drag AppKit in, and why the
  Folder/Leaf name split lives in `SessionName` rather than on `Session`.
  Most of these tests use **git itself as the oracle**: they build a repo with
  `GitFixture` and compare against
  `git log --topo-order` / `git log --graph`, because reproducing those cheaply
  is the whole point of the code under test. See `WortelTests/GitFixture.swift`
  on why its branches are long-lived — a tamer fixture passes against known bugs.
  `PersistedSessionTests` pins the other testable-in-isolation thing: the
  decoder's `decodeIfPresent` defaults, which *are* the sessions.json migrations
  and otherwise only ever run on the one launch that reads an old file.
  `SessionNameTests` pins the Folder/Leaf split for the same reason — a session's
  folder is just the part of its name before the last slash, so a wrong split
  doesn't throw, it silently moves the session.
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
persistence of the session list (order, names, cwds, selection, git-panel
visibility) to `~/Library/Application Support/Wortel/sessions.json`. This is
*app state*, not user config — Wortel stays zero-config. Decoder tolerates older
files missing fields. `saveNow` runs synchronously on termination.

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

**What the watcher watches is not just the work tree**, and a session in a
worktree is why. A linked worktree's `.git` is a *file*; its HEAD, index and
reflog live under the primary's `.git/worktrees/<name>`, so nothing under its own
root moves when you stage or commit there — a watch rooted at the work tree sees
file edits and no git operation at all, and the panel goes on listing files that
were committed minutes ago. So `GitRepoModel` widens the watch to that gitdir
(`GitService.externalGitDir`), and the primary — whose `.git` holds *every*
worktree's state under `worktrees/` — excludes that subtree in exchange, or every
`git add` an agent runs next door walks this work tree. (Only that subtree: a
worktree's commit also writes a ref and objects in the shared `.git`, which the
primary still sees. Rarer, and real news.) The widened watch is the checkout's
own gitdir and not the common dir, which also holds `objects/` — one fetch would
scan the work tree of every open session.

Whether the panel is up is **per session**, not app-wide: it's a property of what
the session is for — a manager sitting in `~` never wants it, the one in a repo
always does. So `GitPanelModel` holds no visibility state of its own. `isVisible`
mirrors the focused `Session.gitPanelVisible`, re-read on every `focus(session:)`
and written back through `setVisible` (the one funnel, so a divider-drag
dismissal is recorded like a ⌘⌥G); `SessionStore` persists it. A session switch
that changes visibility **snaps** the inspector rather than animating it
(`animatesVisibilityChange`) — animating would reflow the terminal on every frame
of a switch that's meant to be instant.

**Which pane** the column shows (`InspectorPane`: Changes / History / Files) is
per session for the same reason and by the same mechanism — `pane` mirrors
`Session.inspectorPane` through the `setPane` funnel. A session with no stored
pane is a real state, not a gap: both an older `sessions.json` and a session
you've never picked a pane on defer to `GitPanelModel.defaultPane`, the last pane
chosen anywhere, so a new session inherits your habit instead of snapping to
Changes. `lastSourceControlPane` is tracked separately so ⌘⌥G coming back from
Files lands on History if that's where you were. One rule drives all three
openers — the toolbar segments, ⌘⌥G and ⌘⌥E — via `GitPanelModel.activate(_:)`:
hidden → open on that pane, showing another → swap, showing that one → close.

**How wide** the column is, on the other hand, is per *occupant* rather than per
session — `MainSplitViewController.InspectorOccupant` (the three panes plus the
Markdown preview, which is a view of no pane at all). A tree of short names, a
diff with a gutter and a rendered page want visibly different widths, and one
remembered width for all of them means every switch is followed by a drag back.
Each occupant carries its own default and its own `minimumThickness`, and
`InspectorWidthStore` persists what you drag it to. Two rules keep that honest:
only a *divider* drag is a preference (a window resize squeezing the terminal to
its floor is not), and the width is committed once the drag settles, because
dragging to the edge is how you close the panel and the last width before it goes
is the minimum. The split view's `autosaveName` still carries the sidebar; the
inspector's width it saves but does not get to decide (see `viewDidLayout`).

**Files pane** (`Wortel/Files/`) — the project as a tree, rooted at the repo
work-tree root (the session's cwd outside a repo, which therefore re-roots as you
`cd`, since outside a repo there's no project to hold still for). Read-only by
design: it opens, reveals, copies paths and feeds them to the prompt, because the
shell beside it does `mv` and `rm` better. Dragging a row into the terminal needs
nothing new — `SurfaceView` already registers `.fileURL` and inserts the escaped
path.

**Move to Trash is the one exception**, and it's the exception that proves the
rule: `rm` has no Trash, so recoverable deletion is the single file operation a
terminal does *worse*. It refuses the root (that's the project), and doesn't
confirm — the Trash is the confirmation, which is exactly why `rm` doesn't get an
entry here and this does.

It inherits the git panel's cost rule, and that is the whole design:

- **Only expanded directories exist.** They're the only ones listed, the only
  ones watched, and the only ones `check-ignore`d. A collapsed `node_modules` is
  one row and no work at all; expanding one is capped at
  `FileTreeModel.listingCap` entries with a trailing "N more items" row, because
  a truncated list that doesn't say so reads as "this is everything".
- **`DirectoryWatcher`, not `GitRepoWatcher`.** FSEvents is always recursive,
  which is exactly wrong here — a session rooted at `~` would watch
  `~/Library`. One `DispatchSource` vnode watcher per open directory instead,
  opened on expand and closed on collapse, with a per-directory debounce so an
  `npm install` inside an open folder can't outpace the UI.
- **Ignored entries are shown greyed, not hidden**, and answered per expanded
  directory by `GitService.checkIgnore` — `status --ignored` would walk
  `node_modules` on every refresh to answer a question about twenty rows. Only
  `.git` is hidden outright; `.gitignore` and `.env` are things you look for.
- **One AppKit view owns a row's left mouse** (`RowClickCatcher`: select,
  double-click to open a preview window, drag the file out). They cannot be
  split: `.onDrag` starts tracking on the first click and **swallows the
  second**, so a double-click reaches neither a tap gesture nor an overlay that
  reads `NSApp.currentEvent.clickCount` while hit-testing. Measured, the click
  counts a row saw went 1, 1, 1, 3, 4 — never 2, which is why four fast clicks
  opened a file and two did nothing. The sidebar reached the same conclusion
  with its native `doubleAction`.
- **⌥ takes the subtree** (⌥-click a chevron, ⌥→/⌥←, or the row's context menu),
  and that gesture is where the cost rule has to be defended rather than stated:
  "expand everything under it" is a promise a tree can't keep. So the walk never
  *descends* into an ignored directory (the one you point at still opens — you
  asked), it stops at `recursiveExpandCap` directories and `recursiveExpandDepth`
  levels even outside a repo where there's no ignore file, it trims each level to
  the remaining budget *before* touching the disk, and it asks `check-ignore` once
  per level rather than once per directory. ⌥-collapse is the mirror image and
  costs nothing: it also *forgets* the subtree's shape, which plain collapse
  deliberately remembers. On the root — which never collapses — it means
  "collapse all".
- **`FileTreeDecorations` is a pure value type** (and the one part of the pane in
  `WortelTests`) because its ancestor roll-up is silently wrong in both
  directions if you reach for `hasPrefix`: `src/foo` changing must not decorate
  `src/foobar`, and a collapsed directory that fails to roll up just looks clean.

The Markdown preview still takes the **whole** column when it opens (a terminal
with two right columns gets cramped), so opening a `.md` from the tree hides the
tree until the preview is closed or the Files segment reclaims it — the same rule
as clicking a `.md` path in the terminal.

**Preview windows** (`Wortel/Preview/`) — double-click a file (the tree, a
Changes row, a file in a commit) or ⌘-click a path in the terminal and it opens
in its own window: Source, Diff or Rendered Markdown, plus Quick Look for
anything that isn't text. See `docs/file-preview.md` for the decisions; the three
that shape the code are that **`DiffView` renders both Source and Diff** (the file
is handed over as an all-context diff, so they match by construction and the diff
highlighter needs no new code), that **loading is `MarkdownPreviewModel`'s old
pattern** (watch the parent directory, because an agent replacing a file replaces
its inode; stat before reading; keep the last good content), and that **previews
are accessories** — they close with the main window and are not restored, so
quitting stays what it was. They are also why the inspector no longer shares its
column with anything.

**The `wortel` command** (`Wortel/CLI/`, `WortelCLI/`) — a Unix socket the CLI
speaks JSON at: `open`, `new`, `rename`, `notify`. `docs/wortel-command.md` is
the user-facing guide, `docs/cli.md` the design record; the three
decisions that shape the code are that **there is no installer** (the binary
ships in the bundle and `GhosttyRuntime` puts its directory on the `PATH` of
every shell it spawns, so it exists inside a session and nowhere else), that
**it never steals focus** (windows are ordered front, the app is never
activated, so a hook firing behind your back can't take your keyboard), and that
**a command means the session it was run in** (`$WORTEL_SESSION_ID`, not an
argument). The point of having it at all is that Wortel then ships no per-agent
integrations: anything that can run a command can drive the app. The CLI target
is named `WortelCLI` and not `wortel` — same-name targets collide in the
intermediates directory on a case-insensitive filesystem, and the app ends up
containing the CLI's executable.

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
