# The git panel

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**Git panel** (`Wortel/Git/`) — the trailing inspector (the side column, which
since 2026-11-26 is a split of the window's tree, `workspace-tabs.md`): a Changes pane (status,
diff, commit box) and a read-only History pane (commit list, graph gutter,
diff), both driven by `GitRepoModel` off the `git` CLI (`GitService`). The
commit box can be turned off in Settings (`AppSettings.showsCommitBox`); the
bar under the diff then appears only to show a git error, since that notice is
the one place a failed fetch, pull or push is reported. The diff can be
hidden (View ▸ Show Diff in Changes, or its divider dragged to the bottom:
`StoredFlag.changesDiff`), and while it is, no diff is loaded. Its
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

**Git is only started on a Mac that has one** (`DeveloperTools`). On a new
Mac `/usr/bin/git` is a stub that raises macOS's "install the command line
developer tools" dialog, and Wortel runs git without being asked. So
`GitService.run` and `runData` first read from the disk whether a developer
directory with a git exists, the way `xcode-select` resolves one (the
selection link if there is one, else Xcode in Applications, else the command
line tools). A yes is kept for the run; a no is read again each time, so git
works the moment an install finishes. While it is missing a command fails
with a sentence and no process, the two panes say "Git is not installed" with
an Install… button (`xcode-select --install`, Apple's installer), and the
permissions popover lists it (`Permissions.developerTools`, read again
whenever Wortel comes to the front, which is also when the pane asks about
its folder again). A selection link that points at a developer directory
which is gone, with Apple's tools still on the disk, is its own answer
(`Git.misdirected`): the panes say "Git cannot run", and the button is Fix,
which types `sudo xcode-select --reset` on a prompt
(`SessionManager.offerCommand`) because the installer has nothing to install.

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
open at once, the counts fill in). No watch per worktree and no timer: on a
large monorepo where `git status` takes 7s, both used to run for as long as the
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

**What a repository can make our git run.** git runs in any folder a terminal
reports (OSC 7, which any program's output can send, not only the shell) and
for a path ⌘-clicked in output, so the folder's own `.git/config` is not ours to
trust. Two kinds of program it can name are switched off for every git we run,
each verified with git 2.54 and pinned in `GitServiceTests` by a fixture whose
program leaves a mark:

- **Diff programs.** Every diff we print gets `--no-ext-diff --no-textconv`
  (`GitService.diffSafetyFlags`), so `diff.external` and a driver's `command`
  or `textconv` are not run. git prints its own diff, so a binary file reads as
  binary even where the user set a textconv for it.
- **Signature checks.** `-c log.showSignature=false` (`GitService.gitArguments`),
  so a repository that turns it on with its own `gpg.program` doesn't run that
  on every `log` and `show`. `gpg.program` itself is left alone: the Commit
  button signs with it when the user's config says so.

**Known limitation:** a filter driver (`filter.<name>.clean`, `.smudge`,
`.process`) that the repository's attributes assign runs on our `status` and
`diff` (verified: `clean` ran on both), and a custom merge driver can run in
`merge-tree` (the merged-branch check). git has no flag that turns drivers off,
and turning attributes off would break Git LFS, whose filter is one. This is
the same exposure as a git-aware shell prompt, which runs `git status` in the
same folder the moment you `cd` into it. Network commands (fetch, pull, push)
and Commit use the repository's config as the user's own git does; those only
run when the user asks.

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
mirrors the focused `Session.gitPanelVisible`, re-read on every `focus(session:)`;
`SessionStore` persists it.

Since 2026-11-26 (branch `flexible-panes`) that flag says less than it did.
The column is a split of the window's tree, and nothing is hidden with its
tabs kept: the split is on screen while its row holds a tab
(`WorkspaceTabs.place` sets the flag) and gone when it holds none
(`workspace-tabs.md`, "Nothing is hidden"). `setVisible` and `isPresented`
are gone from this model. So "is the panel up" is now "are Changes, History
or Files open":

- **⌥⌘B** (`toggle`, View ▸ Show Changes and Files / Hide Changes and Files
  by `toggleCloses`) opens Changes and Files in the column's row, the pane
  last used in front (Changes when that was History), and takes the keyboard
  there. With any pane in that row it closes them (`putAway`) and the
  keyboard goes back to the main row. A terminal, a file or a page in that
  row stays, and the split with it. A pane open in another split is not
  opened again.
- A session switch that changes what is on screen **snaps** rather than
  slides (`animatesVisibilityChange`, read by `MainAreaController.slides`):
  switching sessions is meant to be instant. ⌥⌘B opening the panes slides
  them in, and the tree does the sliding (`SplitTreeView`). Putting them
  away cuts: their tabs are closed first.
- A divider can no longer be dragged shut, so there is no divider-drag
  dismissal to record.
- A session saved with a hidden column comes back with its panes closed and
  anything else in it on screen (`WorkspaceTabs.showHidden`).

**Which pane** the column shows (`InspectorPane`: Changes / History / Files) is
per session for the same reason and by the same mechanism — `pane` mirrors
`Session.inspectorPane` through the `setPane` funnel. A session with no stored
pane is a real state, not a gap: both an older `sessions.json` and a session
you've never picked a pane on defer to `GitPanelModel.defaultPane`, the last pane
chosen anywhere, so a new session inherits your habit instead of snapping to
Changes. `lastSourceControlPane` is tracked separately so ⌘⌥G coming back from
Files lands on History if that's where you were. One rule drives all three
openers — the View menu, ⌘⌥G and ⌘⌥E — via `GitPanelModel.activate(_:)`:
not open → open on that pane, another in front → bring this one forward, this
one in front → close its tab (`putAway`; until 2026-11-26 that hid the whole
column). In the strip it is the same. In the main row the pane goes behind
the session's terminal instead, and in a made split it only comes forward.

**How wide** the column opens is per *session* and the same for every tab in
it (`MainSplitViewController.ColumnWidth`, `Session.sideColumnWidth`): a width
that changed with the tab in front made every tab switch a relayout of the
terminal beside it. A session that has never had its divider dragged uses the
last width chosen anywhere, 440pt before anyone has. Only a *divider* drag is
a preference: `MainAreaController.rememberSizes` writes the width when a
divider is let go and the column's width changed by it. A window resize is
not one.

Since 2026-11-26 (branch `flexible-panes`) that width is only where the
column starts. The column is a split of the window's tree, and once it is
laid out its size is a share of the area, like every split's
(`workspace-tabs.md`, `MainAreaController.sizeNewLeaves`). So a window resize
no longer "goes to the main area": the column grows and shrinks with the
window. The exception that went with the old rule is gone too (a browser in
front of the column took the whole resize, by a holding priority dropped
below the main area's). So are the column's own pane in the window's split
view, the width that pane saved, and closing the panel by dragging its
divider to the edge: a divider stops at a split's minimum, and ⌥⌘B closes.
The split view's `autosaveName` (`window-split`) carries the sidebar's width
and nothing else.
