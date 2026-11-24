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

A file opens in the main area unless you've put one elsewhere, so the tree
stays where it is. One opened into the column still takes the **whole** column
(a terminal with two right columns gets cramped), so opening a `.md` from the
tree there hides the tree until the preview is closed or the Files segment
reclaims it, the same rule as clicking a `.md` path in the terminal.

**A ⌘-clicked link in a terminal** (`Wortel/Ghostty/TerminalLink.swift`).
libghostty finds the link and calls OPEN_URL. Every link is taken and handled
on the main actor (`SessionManager.openLink`). None is left to libghostty:
since Ghostty's `f9e8ef02d` (Oct 2026) its macOS fallback opener refuses the
two kinds a click produces, a matched URL (`unknown`) and an OSC 8 hyperlink
(`osc8`), and opens nothing. In 2026.47.4, the first release on that Ghostty,
no web link opened at all.

- **A path or `file:` URL.** libghostty's own open ran `open` from the app's
  working directory, `/`, so a relative path an agent printed
  (`docs/decisions.md`) opened nothing. It is tried against the terminal's
  last OSC 7 folder (`SurfaceView.reportedPwd`, a side terminal's own), the
  session's `cwd`, its `originCwd`, then the repository root of each (a walk
  up for `.git`, no git), and last one folder below each repository root (never
`~` or `/`), when exactly one folder has it (an agent that went into `macos/` names `scripts/x.sh` from
there, in a shell of its own that never reports a cwd). The regex keeps a sentence's full stop and a
  location (`docs/decisions.md.`, `App.swift:42:7`, `README.md#L12`), so each
  spelling is tried until one exists; `a/` and `b/` from a diff come off
  last. **Every file opens in the preview**, never in its default app, so a
  click can't run a `.command`; at the line, when there was one
  (`PreviewDocument.reveal(line:)`: Diff gives way to Source, the row is
  selected a third of the way down; Rendered lands on the line's block). A
  folder goes to Finder, a package is only revealed. A path found nowhere is
  dropped silently.
- **A server on this Mac** (`localhost`, `127.x`, `[::1]`, `0.0.0.0`,
  `*.localhost`) opens beside the terminal as the running-jobs popover's
  servers do (`GitPanelModel.showInBrowser`: a tab on that server comes
  forward), or in the browser when Settings says servers go there.
- **Anything else** (`TerminalLink.external`), after the rules of Ghostty.app's
  `UntrustedURL`. An `http(s)` link with a host and a `mailto:` with an address
  open in their default app. Another scheme (`vscode:`, `tel:`, `ssh:`) asks
  first, naming the app, the same sheet a browser tab shows. A link with
  control, zero-width, bidirectional or line-separating characters, or with
  no scheme or host, does nothing.

**Open in the file's app** (`Wortel/Preview/ExternalEditor.swift`), the
header button of a preview tab and window. No setting: the
app is the file's default, and Wortel adds the line (the selected one, else
the top of the view), each editor its own way: `vscode://` and `cursor://`
URLs, Zed's and Sublime's bundled command with `path:line`, Xcode's `xed
--line`. Others open the file without it. The button is there when the app is
a known editor (`ExternalEditor.editors`), or the file is text, an image or a
PDF and not a script: an allowlist, because a list of apps to avoid (a
terminal, Python Launcher, the Installer) is only as good as the apps
somebody thought of. A deleted row's line is
taken from the row after it: the editor opens the file as it is now.

**Previews** (`Wortel/Preview/`) — double-click a file (the tree or a Changes
row open it in the preview tab, see `workspace-tabs.md`; a file in a commit,
Open in a row's menu) or ⌘-click a path in the terminal and it opens as a
**tab** (`SideTab.file`, `PreviewTabs`) in the main area (or wherever you
last dragged one, per session; ⌥ for the other place), or comes forward where
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

**⌘P's files** (`FileIndex`, `FileMatch`, `FileListing`, `FileIndexStore`,
`FileSearch`) — go to a file by name, in the session's repository, or its
folder outside one (`manager.branchSource()`, as ⌘Y). The decision and its
numbers are in `../docs/decisions.md` (2026-11-24).

- **Where the list comes from.** In a repository, `GitService.trackedFiles`
  (`ls-files -z`, the index, no walk) plus the untracked files: the git
  panel's current status when it has one (`GitPanelModel.knownStatus`),
  else `GitService.untrackedFiles`, once, behind `backgroundScans`. Outside
  one, `FileListing.walk`: Zed's rules (five levels, VCS folders and
  `node_modules` skipped, no symlinked folders, one volume, a 200k cap that
  titles the section "part of this folder"), readdir with `d_type` on every
  core, repositories inside handed to git. `FileListing.mayWalk` refuses `/`,
  home and anything above it, and a volume's top.
- **The index is immutable.** One byte buffer, offsets, file-name starts and
  a letter mask per path, in byte order so a folder's contents are one range.
  An update builds a new one off the main thread (`FileIndexStore.rebuild`)
  and swaps it in; a search on the old one is never disturbed.
- **Kept current** by a `GitRepoWatcher` with the paths-and-flags callback:
  `.git` (or a linked worktree's gitdir) re-reads `ls-files` when the index
  file's size or date moved; a changed folder is re-read by itself
  (`FileIndexStore.difference`), new files go through `check-ignore`, a new
  folder through `ls-files --others` on it alone; dropped events rescan the
  untracked files under them. A walked folder is walked again. Four folders
  kept at most, each let go (and its watch ended) 30 minutes after its last
  search, checked every five minutes; nothing is built until ⌘P opens.
- **What the watch leaves alone.** A folder git ignores is asked about once
  and its events dropped from then on; events keep coming from a dev
  server's cache, so an update put off past a second runs anyway. A
  repository, submodule or worktree inside the checkout is its own (git
  fails a whole `check-ignore` for one path in a submodule), and a
  `check-ignore` with no answer adds nothing rather than everything. The
  re-read folder is compared with git's list skipping only `.git`, with any
  symlink a file, since git tracks those as entries.
- **Ranking** (`FileMatch`): fzf v2's dynamic programme over bytes, a word
  found in the file name a tier above one found only across the path, a
  shorter name first among names, then small boosts for files changed here
  (the panel's status) and files opened lately (`RecentFiles`, a ten-day
  half-life), then the shorter path. One or two letters score file names
  only. A query that extends the last one searches only its survivors; every
  key cancels the ranking before it. `FileMatchTests` pins the order on real
  Linux paths.
