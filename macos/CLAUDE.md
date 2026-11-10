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
- **One Wortel per data folder.** A second copy launched while one is running
  (any build, any worktree) brings the running one forward and exits
  (`InstanceLock`), because two copies sharing `~/Library/Application
  Support/Wortel` each write their stale view of it back on quit: that is how
  agents lost their light/dark subscription. To try a build *beside* the one
  you're working in, give it a folder of its own; it gets its own sessions,
  keeper and `wortel` socket and never touches the real ones:

  ```sh
  open -n --env WORTEL_DATA_DIR=/tmp/wortel-try path/to/Wortel.app
  ```

  Keep the path short (sockets live in it; 104-byte limit). Its keeper keeps
  its shells after it quits, like the real one; stop it by pid when done.
  UserDefaults (sidebar width, folder roots) are still shared, by bundle ID.
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
- **`./scripts/verify-running-jobs.py`** checks the running-processes feature
  against a real machine: real servers in a real `/usr/bin/login` pty session,
  in all 44 shapes agents and people start them in, scanned by the shipping
  code. Fixtures cannot catch a shape nobody thought of, and that is what every
  bug in that feature has been. Run it before releasing a change to
  `Wortel/Processes/`.
- **`./scripts/try-git.sh`** builds a throwaway repo with every git situation
  the panel handles (branches busy in other folders, agent worktrees with and
  without changes, something running in one, ahead and behind, a branch in
  the way of a local edit) and opens a session in it, with a checklist to
  look over before a release touching `Wortel/Git/`. `--clean` removes it.
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

**Where a new session starts** is `SessionManager.newSession`, and it is the one
piece of session handling with a rule worth stating. A sidebar **folder carries a
directory** (`folderRoots`, UserDefaults beside the other three folder keys) —
before that it was purely the part of a name before the last slash, so "New
Session in “GFPC”" filed a session under GFPC and started it wherever the
*selected* session was standing, which looked exactly like it had worked. The
resolution order is: an explicit `cwd` (the CLI, a worktree, ⌘O), then the named
folder's directory, then the selected session's **`originCwd`**, then that
session's folder's directory, then nil so `wortel.conf`'s `working-directory =
home` answers. Two things about it are load-bearing:

- **`originCwd`, not `cwd`.** `cwd` tracks the shell's pwd reports, so
  inheriting it meant a session opened beside one you had taken three levels
  deep started three levels deep too, and the next one inherited the drift
  again. The birth directory is the deliberate answer and never moves.
- **Each remembered path is `stat`ed before it is used** (`existingDirectory`),
  because `chdir` is best-effort: a project that moved on disk would otherwise
  silently start the shell somewhere else instead of falling through to the next
  answer. The stored root is *not* cleared when that happens — an unmounted
  volume must not look like lost configuration.

`FolderRoot` (pure, in `WortelTests`) holds the path handling: containment that
respects component boundaries, the deepest-root match ⌘O files into, and the
one-time derivation that gives folders predating the feature a directory from
where their sessions already are.

**`SessionStore`** (`Wortel/Sessions/SessionStore.swift`) — debounced JSON
persistence of the session list (order, names, cwds and origin cwds, selection,
git-panel visibility) to `~/Library/Application Support/Wortel/sessions.json`.
This is *app state*, not user config — Wortel stays zero-config. Decoder
tolerates older files missing fields. `saveNow` runs synchronously on
termination.

**Terminal modes across a reattach** (`Wortel/Ghostty/TerminalModes.swift`) —
the keeper keeps a session's shell alive across a relaunch, so the *program*
never restarts, but its terminal does: a new libghostty surface starts with
every mode at its default while the program still believes what it set. That
costs a paste its brackets (`?2004`), and each pasted line then arrives as
Enter. So the app watches the output it already handles, records the sticky
modes, persists them per session, and re-declares them into the new surface
*before* the keeper's replay. **The watching cannot live in the keeper**: while
a session is attached the app reads the pty itself, which is exactly when a
program declares its modes. The replay's own queries get answered by the new
surface, long after the program stopped waiting, so those answers are dropped
(`ReplayAnswers`, `PtyHost.writeFromTerminal`) until a marker query parsed
after the replay comes back: libghostty writes answers from its IO thread a
moment after parsing, so "the replay was written" is not "its answers are out".
See `docs/terminal-modes.md`.

**Attention** (`SessionManager`'s Attention section, `docs/agent-signals.md`)
— a session that wants you gets a dot, the Dock badge and a notification,
unless you're looking at it: Wortel frontmost, window on screen, session
selected, **and the Mac touched in the last minute** (`userIsAway`, the
window server's idle time, read when a signal arrives). An attention raised
on the session on screen while you were away is cleared only by your input in
its terminal or selecting it, never by activation, the window uncovering or
a `wortel send` (`raisedWhileAway`, `sendText(scripted:)`). A turn end's notification body is the start of the
agent's last answer (`AgentAnswer`, from Claude's transcript, Codex's rollout
or Pi's session file), with the old fixed text as the fallback.

**Session naming** (`Session.NameSource`, `Wortel/Sessions/AgentTitle.swift`,
`Wortel/Sessions/PromptCapture.swift`, `Wortel/Ghostty/PromptTap.swift`,
`SessionNameGenerator`) — a row's name comes from the best source that has
spoken, in this order: a user rename, the agent's own terminal title (Claude
Code titles its conversation from the first prompt and pushes `✳ <title>` as
the terminal title, which `AgentTitle` parses), a title the on-device model
makes from the first prompt the user typed into the agent (a `PromptTap` on
`PtyHost.write` reads it back for any agent, no hooks or config files
involved), the model's screen summary, and the placeholder (the directory, or
the branch for a worktree session). Worktree sessions are named for their task
and carry the branch on a second row line. See `docs/session-naming.md` for
the reasoning, the privacy scoping of the tap, and what the other tools do.

**UI shell** (`Wortel/UI/`) — three AppKit split panes (`MainSplitViewController`)
hosting SwiftUI content, in an AppKit window (`AppDelegate`). The titlebar is
Wortel's own (`TitleBars.swift`): the window keeps an *empty* toolbar only for
its height and the centred traffic lights, the titlebar is transparent, and each
pane draws its row of a flat grey band (the ChatGPT app's look). The reason is
that on macOS 26+ every toolbar item, custom views included, sits on a Liquid
Glass capsule, and AppKit has no switch to stop that. The window's vibrancy is
one behind-window material under everything (`BackdropController`); only the
pages (terminal, column) are opaque. Sidebar selection is a custom neutral
pill rather than `List(selection:)` because the sidebar never holds keyboard
focus (the terminal does). `TerminalHostViewController` is the key trick: it keeps **every**
session's `SurfaceView` in the hierarchy and switches via
`isHidden`/occlusion/first-responder — never `removeFromSuperview`, never a
rebuild — so switching back is instant with no flash. `updateNSViewController`
fires on any observable change, so `show()` early-returns when already showing
the surface (otherwise it would steal focus from the rename field).

**Sidebar selection and order** (`SidebarOutlineView`, `SessionSelection`,
`SidebarSort`, both pure and in `WortelTests`). ⌘-click and ⇧-click select
several sessions (the range runs over rows as drawn, across sections); the
**lead is always `selectedID`**, the session on screen, and a modifier click
never moves it, so selecting four unread sessions doesn't start four shells or
read them. Esc or typing in the window collapses it (an `AppDelegate` key
monitor, since the sidebar never has the keyboard; Esc is taken only while a
selection of several exists). Right-click inside it keeps it and the menu acts
on all of them (`SessionActions.menu(for: [Session])`, one change and one save
each); outside, it collapses onto that row. Dragging a selected row drags the
selection. **View ▸ Sort Unread First** draws each section with the sessions
that want you first (louder kinds, then a hollow ring, then most recent). It is
a view over the stored order, computed in the outline's coordinator and never
written back, so saving and `normalizeOrder` never see it. ⌘1-9 do: they
count the rows as drawn (`shortcutIDs`, from the outline's `publishRows`), so
the number shown while ⌘ is held is the one that selects it. ⌥⌘↑/↓ and the
row picked after a close follow the drawn rows too (`sidebarRowOrder`,
`SidebarStep`). The selected row sorts by the key it had when it was last drawn until selection leaves it
(it was read the moment you selected it), and nothing re-sorts while the
pointer is on a row or a button is down; rows slide with `moveItem`, not a
reload. A drop is placed *before the row drawn below it* (`moveSessions(before:)`),
which means the same thing in the stored order as on screen, so dragging while
sorted still writes the manual order.

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

**The panes show the session's own folder**: where it was started
(`GitPanelModel.homeFolder`, its `originCwd`), so a worktree session's
worktree (New Worktree Session starts one there),
else its repository. Not where an agent is working: an agent `cd`'d or
writing into another worktree of the same repository is that worktree's
business, usually removed when it's done, and following it (or pointing at
it with "N changes in …", since removed) left you somewhere you couldn't
place. Another checkout is shown only when picked from the worktree chip,
with Back to return. The shell is followed only out of the repository
(`shownFolder`): a `cd` into a different one is a different project, and
staying behind would commit to the one you left; a session started outside
any repository follows its shell too. Same repository or not is read off
the disk (`GitWorktree.commonDir(containing:)`), no git per prompt.

**Only the repo on screen does git work.** `GitPanelModel` caches a model per
root it has shown, and each keeps its watch, but only the shown one scans on a
write (`GitRepoModel.setActive`); the rest mark themselves `isStale`, and a
switch back re-reads only if stale (the header's spinner covers the catch-up).
Before this, an agent merging in one worktree woke a full scan in every cached
checkout at once. The other worktrees are the manager's cached listing
(`worktreeListings`, no `git worktree list` of the panel's own), and what's in
them is read **only when asked**: the worktree or branch list opening (they
open at once, the counts fill in). No watch per worktree and no timer: on the
work laptop's monorepo (`git status` 7s) both used to run for as long as the
panel was up. Those reads go through `GitService.backgroundStatus`, one at a
time app-wide, reuse a cached model's status when it's current, and stop when
a newer read supersedes them or the list closes. Other checkouts are named for
the session in them (`CheckoutPlace`), not their folder, which keeps the
placeholder branch's name forever. Every git we run gets `-c core.fsmonitor=false`: with fsmonitor in the
user's config each repo touched left a daemon running for good, for no gain
(our reads never write the index the daemon's answers are keyed to). The Files
tree follows the same rule: it doesn't re-root, re-list or `check-ignore` while
it's off screen, and catches up when shown. And a hidden terminal takes no
resize (`SurfaceView.isHidden`): switching between sessions whose columns
differ used to re-wrap every session's terminal and SIGWINCH every agent.

**A new worktree gets the ignored files it needs to run** (`WorktreeInclude`):
whatever `.worktreeinclude` names in the checkout it was made from (gitignore
syntax, the convention Claude Code, Codex, Conductor and Orca share), else
`.env*`. Only ignored, untracked files; never into an existing file or a nested
repository; cloned, not copied, where APFS allows. The listing is
`ls-files --others --ignored --directory`, which reports `node_modules` as one
line instead of walking it, and a pattern only looks inside an ignored directory
when it names a path there. A worktree that already existed is never written
into. Anything that didn't copy is held on the preparing page
(`WorktreePreparation.warnings`) until "Open Session", because the terminal
replacing the page would hide it.

**Worktrees: the session is the unit** (`docs/worktrees.md`). You manage
sessions; a worktree is where one lives. One way in: ⇧⌘N New Worktree
Session (`BranchSheet`: a placeholder name selected so Return is instant, From,
and Location, which writes the repository's `wortel.worktreePath`; an existing
branch or a `#123` in the name field checks that out; `wortel new --worktree`
skips it). **Starting a session has four ways and only four** (⌘N, ⌥⌘N at
home, ⇧⌘N, ⌘O): Open Branch, Fork Session, Change Directory (`wortel cd`) and
New Folder were all cut on 2026-11-09 for being more ways in than anyone kept
apart. Don't add a fifth without that argument. One way out: closing (⇧⌘W, ×, `exit`) a session that lives in a
worktree **archives** it (`SessionManager.archive`), then, after the row has
moved, inspects the worktree and Trashes it only when there's nothing to keep
(`WorktreeCloseDecision`). Archived sessions are in `archived-sessions.json`,
never `sessions.json`, which an older build would start them from; restoring
one goes through the same `restoredSession` launch uses, agent resume and all.
The sidebar shows open sessions only: **⌘P** is where archived ones are
found once you type (`OpenTarget`, listed under the matching sessions), with
the worktrees no session is in, whoever made them ("Not open"), from one cached `git worktree list` per repository
(`worktreeListings`, refreshed by a vnode watch on `.git/worktrees` and after
creates and archives; never per row or on a timer). An Archived fold per
folder was tried and dropped as clutter.

**Any linked worktree is a worktree; only Wortel's are Wortel's to remove.**
`GitWorktree.linked` reads the nearest `.git` file on every `cd` (no git): the
row gets the glyph and branch line, ⌘O files it with its repository.
Ownership is a **marker** in the worktree's git folder and
`branch.<b>.wortelCreated` in git config (`GitWorktree.Ownership`), not a path;
`~/.wortel/worktrees` and `worktree/` still count, for what was made before.
Never lock a worktree, ours or anyone's. A repository may put its worktrees
elsewhere with `git config wortel.worktreePath` (a folder or a `{repo}`/
`{branch}` template; the New Worktree sheet's Location field, or `includeIf` for a
whole tree of repositories); one inside the repository goes in `info/exclude`.
A generated branch is renamed for the session's name while unpushed
(`GitWorktree.mayRename`); the folder never moves, since agents key history by
directory, and a folder that held a worktree (or Claude history) is never
reused. A worktree row is marked as preparing *before* it's selected
(`makeSession(prepare:)`): selecting starts the shell, and one started with no
directory came up in the keeper's, `/`.

**Prompt history** (⌘Y, `PromptHistory`, `PromptHistoryStore`,
`PromptHistoryModel` in `SessionSwitcher.swift`) is ⌘P's panel in a fourth
mode: everything typed to Claude Code, Codex or Pi, the session's project
first (its repository home, so every worktree of it counts), and Return types
the pick into the session's own terminal **unsent**, as a paste
(`SurfaceView.sendText`, bracketed when the program asked for `?2004`; when it
didn't, the lines are joined, since an unbracketed newline is Return). Wortel
stores nothing for it: the agents' own files are read when the panel opens,
off the main thread, from their tail (4 MB a file; Pi's newest conversations
within a 16 MB budget), cut at 5000 entries, and kept only in memory keyed by
size and modification date. That memory is a value (`PromptHistoryStore`),
not a locked shared object: the model keeps it on the main actor and a load
reads with a copy and hands the copy back, so the main-thread rule holds. Ranking runs off the main thread too, the
previous one cancelled per keystroke. No index on disk, ever: that would be
Wortel keeping the user's prompts, which `docs/session-naming.md` promises it
doesn't.

Claude keeps a conversation resumed from another folder in the *old*
folder's project directory and appends there, so
`AgentResumeStore.claudeTranscript(id:cwd:)` looks in every project folder when
the session's own has nothing.

**Removing a worktree never loses work without you choosing it.** Closing a
session archives it (above); Clean Up Worktrees… goes through `WorktreeCleanupSheet`, which inspects first
(`WorktreeCleanup.inspect`): uncommitted or untracked files, something running
there or another session in it, a lock, or a folder that isn't a checkout any
more → **blocked**, with the reason; commits found on no other branch or
remote → the folder may go, the branch stays unless you tick it; otherwise
**safe**, folder and (Wortel-made) branch both. Removal re-inspects, moves
the folder to the **Trash** (a clean status says nothing about an ignored
`.env`), then drops only that registration (`worktree remove` on the now-missing
folder, not `prune`, which would also forget a worktree on an unmounted
volume; `addWorktree` likewise drops only a stale registration in its way).
Only worktrees Wortel made, and only branches it created, are ever Wortel's to
remove; a commit count git can't give is treated as "may have commits". A branch whose commits are on no other branch
but whose **work is already in the default branch** (squash or rebase merged,
the way most pull requests land) is safe too (`WorktreeReport.mergedInto`,
`GitService.isMerged`): `merge-tree --write-tree` of the branch into trunk
gives trunk's own tree. Its cost follows the branch, not trunk's history. A
branch that changed nothing since it forked is never "merged" (its commits are
all it has), and trunk editing the same lines since says no, which keeps the
branch: the safe way to be wrong. The git panel says "Merged into origin/main"
for the clean worktree on screen, cached per (HEAD, trunk), and offers Close
Session when the session lives there (closing is how a worktree is put away).
Bring Here counts an archived session's worktree as in use: restoring it
needs its branch.

**The changes list holds a selection, not a selected row.** ⌘ toggles a row, ⇧
takes the run from the anchor, ⇧↑/⇧↓ do the same from the keyboard, ⌘A takes the
lot (free to bind because the menu bar keeps Select All on ⌘⇧A so plain ⌘A
reaches whoever has focus). The range runs over the list *as drawn*, so it can
span Staged Changes and Changes in one sweep; what each row means stays per row,
which is why the context menu offers Stage and Unstage separately, each acting on
its own half. Three rules keep it honest:

- **The lead is always in the selection**, and it's the row the diff pane shows,
  drawn at full accent where the rest of the selection sits back at 0.55. Blanking
  the diff on a multi-selection would take it away at exactly the moment you're
  deciding what to discard, and five identical pills with one diff under them
  don't say which. `ChangeSelection` (pure, in `WortelTests`) exists for this: a
  range one row wide, an anchor that moves when it shouldn't, a lead left on a
  deselected row — none of them throw, the list highlights exactly what was
  selected, the dialog counts exactly what was highlighted, and the first news is
  a file you never pointed at being gone.
- **Right-click inside the selection keeps it; outside collapses onto that row**
  (the Finder's rule). It's what lets a destructive menu item be trusted: what
  the menu acts on is always what's highlighted behind it. The row's hover +/-
  button is the exception and acts on its row alone, because it's attached to one.
- **A bulk action is one `git` per kind and one status**, never one per file
  (`GitService.discardCommands`, `chunked`). Each mutation ends in a full worktree
  walk, so forty rows a file at a time is forty of them next to a terminal that
  has to stay smooth, and the three kinds of discard are not interchangeable:
  `clean` on a tracked path leaves the edit in place, `restore` on an untracked
  file fails outright, and both look like a discard that worked. Paths are split
  by byte budget because an argv past `ARG_MAX` fails to spawn rather than
  returning a git error.

**What the watcher watches is not just the work tree**, and a session in a
worktree is why. A linked worktree's `.git` is a *file*; its HEAD, index and
reflog live under the primary's `.git/worktrees/<name>`, so nothing under its own
root moves when you stage or commit there — a watch rooted at the work tree sees
file edits and no git operation at all, and the panel goes on listing files that
were committed minutes ago. So `GitRepoModel` widens the watch to that gitdir
(`GitService.externalGitDir`), and the primary — whose `.git` holds *every*
worktree's state under `worktrees/` — excludes that subtree in exchange, or every
`git add` an agent runs next door walks this work tree; `objects/` goes too, as
a `git add` there writes a blob and nothing else of this checkout's. (A
worktree's commit also writes a ref in the shared `.git`, which the primary
still sees. Rarer, and real news.) Any linked worktree *inside* the checkout
(`wortel.worktreePath = .worktrees`, Claude Code's `.claude/worktrees`) is left
out as well, a folder of nothing but worktrees as one path; FSEvents takes
eight exclusions and the callback filters past that
(`GitRepoWatcher.exclusions(forCheckoutAt:)`, re-read after each status). The
widened watch is the checkout's own gitdir and not the common dir, which also
holds `objects/` — one fetch would scan the work tree of every open session.

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
openers — the View menu, ⌘⌥G and ⌘⌥E — via `GitPanelModel.activate(_:)`:
hidden → open on that pane, showing another → swap, showing that one → close. A
pane in the main row or the strip toggles there instead.

**How wide** the column is, is per *session* and the same for every tab in it
(`MainSplitViewController.ColumnWidth`, `Session.sideColumnWidth`): a width
that changed with the tab in front made every tab switch a relayout of the
terminal beside it. A session that has never had its divider dragged uses the
last width chosen anywhere. Two rules keep that honest:
only a *divider* drag is a preference (a window resize squeezing the terminal to
its floor is not), and the width is committed once the drag settles, because
dragging to the edge is how you close the panel and the last width before it goes
is the minimum. A window resize goes to the main area, except while a browser is
in front of the column: then the column takes all of it (its holding priority
drops below the main area's) and the terminal holds still, and the width it
leaves is kept like a drag's. The split view's `autosaveName` still carries the sidebar; the
inspector's width it saves but does not get to decide (see `viewDidLayout`).

**Tabs and the workspace** (`WorkspaceTabs`, `SideTab`, `GitPanelModel`,
`Wortel/UI/SideTabStrip.swift`, `MainArea.swift`, `BottomStrip.swift`) — each
session has three places for tabs, modelled on the ChatGPT app's bounded layout
(a fixed set of regions, never a free grid of splits):

- **the main area's row**: the session's own terminal (`SideTab.session`, by
  the session's name) plus whatever is opened or dragged there;
- **the side column's row**: Changes, History, Files, side terminals;
- **the bottom strip** under the main area (⌘J).

Besides panes and terminals, a tab can be a previewed file (`SideTab.file`) or
a browser (`SideTab.browser(id)`, `Wortel/Browser/`), opened blank from "+" or
on a server from the running-jobs popover. A browser's address lives on its
session (`browserAddresses`, persisted) and its live web view in
`BrowserTabs`, not in the view, so moving the tab doesn't reload it.

A file or browser opened without saying where goes where you last *moved* one
of its kind in that session (`WorkspaceTabs.home(for:)`, the column until
then); ⌥-click puts it in the main area once without teaching that.

A tab is in exactly one row; the one in front fills its area. Any tab goes in
any row, except the session's terminal, which never leaves the
main row and can't be closed: dragged onto the column it **swaps sides** instead,
as ChatGPT's chat does. Opening a tab shows its row, closing the last hides the
column or strip (instantly), hiding keeps the tabs, ⌘⇧T reopens the last closed
in the row you're in. All of those rules live in **`WorkspaceTabs`**, a pure value
with its own tests (`WorkspaceTabsTests`); `Session.workspace` reads the
session's individually-observed fields into it and writes back only what
changed, and `GitPanelModel` wraps each change with the side effects (the pane
shown, the keyboard, saving). Change a rule there, not in the model.

Things that look like detours and aren't:

- **Terminals are never rebuilt when they move.** Side terminals (`sideSurfaces`
  on the session, keyed by tab id, which is also their keeper id so they
  survive a relaunch) live in always-mounted hosts (`SideTerminalHostController`)
  that hide rather than remove; moving a terminal between rows is `addSubview`
  into the other host. The session's own terminal stays mounted in the main
  area and a pane in front of it is a cover that takes the keyboard away from it.
- **The titlebar tabs are NSControls and the window is `isMovable = false`.** The
  window server moves a window from any press in a transparent titlebar that
  isn't on a control, whatever `mouseDownCanMoveWindow` says; the rows start
  window drags themselves (`performWindowDrag`) from their empty space.
- **Sidebar commands are Wortel's own** (`toggleSessionSidebar:`), not AppKit's
  `toggleSidebar:`: SwiftUI's hosting views answer that one on its way up the
  responder chain and swallow it.
- **Terminals don't resize during pane animations** (`Motion.pane`,
  `SurfaceView.holdResizes`): one resize when it lands instead of one a frame,
  each of which made the program inside redraw. Collapsing panes never resize a
  terminal below 40×20pt for the same reason.

Width: the column's is per session and the same for every tab, and it may grow
until the terminal has 320pt; the strip's height is app-wide. Tab drags are
resolved by `TabDragController` against the rows and a few drop zones (the
main area, the column, the strip, the far edge for swapping), each only for
tabs allowed there. Side terminals' processes count as the session's
(`processRoots`); agent tracking, naming and resume follow the main shell only.

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

**Previews** (`Wortel/Preview/`) — double-click a file (the tree, a Changes
row, a file in a commit) or ⌘-click a path in the terminal and it opens as a
**tab** (`SideTab.file`, `PreviewTabs`) in the column, or comes forward where
it already is: Source, Diff or Rendered Markdown, plus Quick Look for anything
that isn't text. The tab hosts the same document and view as a window, and its
header's "Open in Window" turns it into one. One tab per file; no replaceable
preview tab (tried in the window era and removed, see the doc). See `docs/file-preview.md` for the decisions; the three
that shape the code are that **`DiffView` renders both Source and Diff** (the file
is handed over as an all-context diff, so they match by construction and the diff
highlighter needs no new code), that **loading is `MarkdownPreviewModel`'s old
pattern** (watch the parent directory, because an agent replacing a file replaces
its inode; stat before reading; keep the last good content), and that **previews
are accessories** — they close with the main window and are not restored, so
quitting stays what it was. They are also why the inspector no longer shares its
column with anything.

**The `wortel` command** (`Wortel/CLI/`, `WortelCLI/`) — a Unix socket the CLI
speaks JSON at: `open`, `new`, `rename`, `notify`, `mark`, and
`list`, `read`, `send`, `wait`. `docs/wortel-command.md` is
the user-facing guide, `docs/cli.md` the design record; the decisions that
shape the code are that **there is no installer** (the binary
ships in the bundle and `GhosttyRuntime` puts its directory on the `PATH` of
every shell it spawns, so it exists inside a session and nowhere else), that
**it never steals focus** (windows are ordered front, the app is never
activated, so a hook firing behind your back can't take your keyboard), and that
**a command means the session it was run in** (`$WORTEL_SESSION_ID`, not an
argument), except the four that **reach other sessions** by id or name
(`WortelReach.swift`): `read` the screen, `send` a paste and a Return through
the same calls ⌘V and the key take, `wait` for new text, idle or exit with the
connection held open (never the main thread). `send` has **no prompt and no
label**, like a person typing; the trust boundary is the user's own sessions,
since the binary only exists inside them. `list` and `wait --idle` read
`SessionManager.activity(of:)`, the sidebar's own busy and attention state. The point of having it at all is that Wortel then ships no per-agent
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

**The global hotkey** (`Wortel/GlobalHotkey.swift`) — ⌃⌥⌘. shows and hides the
app from any app on the machine, and it is the one binding the menu does *not*
own. It is a Carbon `RegisterEventHotKey` rather than an
`NSEvent` global monitor for two reasons: a monitor needs the Accessibility
permission, which a zero-config terminal should never have to ask for, and it
only observes the chord instead of claiming it, so the keypress would also land
in whatever app you were in. Registration is hardcoded and unconditional —
there is no settings UI to put a switch in, and the chord is chosen to be one
nothing else wants.

The App menu carries a matching "Show/Hide Wortel" item, which is not a
conflicting second binding: a registered hot key is consumed before AppKit scans
the menu, so that item displays the chord and never fires on it. It becomes the
real (in-app only) binding exactly when registration failed because another app
owns ⌃⌥⌘., which is the only case where a fallback is worth anything.
`AppDelegate.toggleAppVisibility` is the shared action, and it undoes hidden,
buried and miniaturized on the way up, because someone pressing this key means
the same thing by all three.

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
- **Nothing about the user's work leaves the machine.** Wortel reports anonymous
  feature usage (`Wortel/Telemetry/`, opt-out, `docs/telemetry.md`) and that is
  the whole of it. No case in `TelemetryEvent` takes a `String`, which is what
  makes "could this leak a repo name" a question the compiler answers rather
  than one you have to audit. Adding a `String` parameter to any event is the
  change that breaks the promise on wortel.sh/privacy; if a question needs a
  value that is not a small closed set, the answer is a bucket or no event.
- Deliberately **feature-minimal**: no settings UI, no user-config loading. The
  *terminal* has no tabs and no splits of its own: sessions are Wortel's tabs,
  and libghostty's tab/split actions still return `false`. The one split is the
  side column, and its tabs are Wortel's (see **Tabs and the workspace**), not
  libghostty's.
- Resources are shipped as **folder references** (`Resources/terminfo`,
  `Resources/ghostty`) landing in `Contents/Resources/`; the Zig core locates
  them via the `terminfo/78/xterm-ghostty` sentinel. Don't restructure those
  paths.
- `GHOSTTY_BIN_DIR` points at `Resources/ghostty/bin`, which holds one small
  `sh` script named `ghostty` that answers `+ssh-cache` (the only `ghostty`
  command the integration runs). Without it the "terminfo already installed on
  this host?" check always failed, so every `ssh` reinstalled it, printed a
  setup line and left a `/tmp/ghostty-ssh-*` directory. The cache is
  `ssh-terminfo-hosts` in the data folder, 30-day entries. Keeper-spawned
  shells only: the exec fallback gets whatever libghostty sets.
- `GhosttyRuntime` init pins config loading to the bundle only — never
  `ghostty_config_load_default_files` (leaks the user's real config) or
  `load_cli_args` (reads Xcode debug flags on macOS).
