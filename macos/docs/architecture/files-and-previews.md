# The Files pane and previews

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

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
