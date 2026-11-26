# Tabs and the workspace

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**Tabs and the workspace** (`WorkspaceTabs`, `SideTab`, `GitPanelModel`,
`Wortel/UI/SideTabStrip.swift`, `MainArea.swift`, `SplitLeaf.swift`,
`BottomStrip.swift`). Everything beside the sidebar is one tree of splits,
and every split is a row of tabs over a page (**One tree of splits**, below).
A session has one to begin with, and Wortel opens two more where they have
always been:

- **the main row**: the session's own terminal (`SideTab.session`, a tab
  named after the session, pinned: no close button, no menu) plus whatever
  is opened or dragged there. Always there, and always shown as tabs, a lone
  terminal too;
- **the side column** (`.side`): where Changes and Files open by default
  (⌥⌘B). A split at the outer edge, there while it has tabs;
- **the bottom strip** (`.bottom`) under the main row: where ⌘J's terminal
  opens. There while it has tabs.

Neither can be hidden: a split is on screen while it holds a tab (**Nothing
is hidden**, below). "Side column" and "bottom strip" are names for those two
default places and for their leaves in the code. No menu uses them.

Every other split is one somebody made (⌘D, ⇧⌘D, a tab let go on an edge).
Until 2026-11-26 those three were fixed regions, modelled on the ChatGPT app's
bounded layout, and the column and the strip were AppKit panes of their own
beside the main area. The window is still arranged that way. It is no longer
built that way, and since the same day every row is the same row (`PaneBar`,
below).

Besides panes and terminals, a tab can be a previewed file (`SideTab.file`),
a browser (`SideTab.browser(id)`, `Wortel/Browser/`), opened with no address
from an empty tab's page or ⇧⌘L, or on a server from the running-jobs
popover, or an **empty tab** (`SideTab.blank(id)`, **The empty tab**, below),
which is none of them yet. A browser's address lives on its
session (`browserAddresses`, persisted) and its live web view in
`BrowserTabs`, not in the view, so moving the tab doesn't reload it.

**Find in a page** (`BrowserFind`, one per `BrowserPage`). Edit ▸ Find's three
items are the file tab's (`showPreviewFind:` and its two neighbours);
`AppDelegate.findTarget` picks what they act on, the tab in front of the area
you're in and then the column, the main area and the strip: a file that is
text, or a browser that is somewhere. The bar is `FindBar` (`Wortel/UI/`),
the same view a file tab shows. The search is `WKWebView.find`, the public
call, which marks one match and says found or not: no count. Typing collapses
the selection to its start before each search, or every letter would move to
a later match. ⌘E (`useSelectionForFind:`) is enabled only with the keyboard
in a page. Nothing here runs while the bar is closed.

**A file as a page.** `wortel open x.html` and a ⌘-clicked `.html` path open
a browser tab on the file (`AppDelegate.openPage`, then
`GitPanelModel.showInBrowser`), where browsers go in that session. A tab
already on that file comes forward: servers are matched by host and port,
files by path (`BrowserAddress.showsSame`), since every file has neither.
Settings' "servers go to the browser" does not apply. The address is stored
as any browser tab's is, so the tab is back after a relaunch.

- **Reload on change** (`BrowserPageWatch`). After each load the page is
  asked which addresses its markup loads (`link`, `script`, `img` and the
  like, run in `.defaultClient` so the page's scripts can't answer for it),
  and the page's file plus at most 32 of those that are local files are
  watched, each with a vnode watch on the file and one on its folder,
  `PreviewDocument`'s pattern. An event is followed 150 ms later by a stat of
  the watched files, and only a file whose date, size or inode moved reloads
  the page (`reloadFromOrigin`). A file that is gone changes nothing. Any
  `file:` address a tab is on is watched this way, a page or not.
- **Off screen** it costs the open descriptors. A change while the tab is not
  showing sets `reloadWhenShown`, the flag a page that crashed off screen
  uses, and the reload happens when the tab is shown. A tab that was never
  shown has no page and no watch.
- **Page · Source** (`BrowserPage.showSource`, `ModeSwitch`). On an `.html`
  file the header has the pill a file tab has for Diff · Source, and View ▸
  Show Page Source (⌥⌘U) does the same. Source is `PreviewContent` on a
  `PreviewDocument` of the tab's own (`PreviewTabs.sourceDocument`), laid over
  the web view. The web view is not hidden or unloaded, so the page keeps its
  scroll, its state and its reloads, and Page is one cut back. The keyboard
  is taken off the covered page. The document lives until the tab goes to
  another address. ⌘F searches whichever is showing
  (`AppDelegate.findTarget`, `shownSource`). When the column is too narrow for
  the pill and 72pt of address, the pill is one `</>` button
  (`ViewThatFits`): squeezed, it lost its words.
- **The address field** shows a file as `folder/name.html`, the whole
  `file:` address when it has the keyboard, and takes a `file:` address or a
  path from `/` or `~` (`BrowserAddress.url(from:)`).

Measured in an off-screen web view, 2026-11-25, macOS 27.0, in a process
that is not sandboxed, as the app is not: `load(URLRequest)` on a `file:`
address loads a stylesheet beside the page and one in the folder above it,
so `loadFileURL(_:allowingReadAccessTo:)` is not used; Resource Timing lists
nothing for `file:` resources, which is why the markup is asked instead;
`reload` keeps the scroll (900 before, 900 after).

What such a page can reach, measured the same way: nothing on disk but what
its markup loads. `fetch` and `XMLHttpRequest` of a file beside it and of
`/etc/hosts` were both refused, and a frame showing a file beside it could
not be read from the page. Its scripts do run and can use the network, as
any page's in the tab can. `WKPreferences` is left at its defaults for this
reason: the private "file access from file URLs" switches stay off.

Checked in a test copy, same day: the page loaded from `wortel open`, a save
by rename and a stylesheet written in place each reloaded it once, another
file in the folder did not, a change while the tab was behind another waited
until it was shown, and the tab was restored and loaded after a relaunch.
Not checked there: ⌥⌘U and the pill in a live window.

**Sign-ins.** Pages use WebKit's default data store, which is kept per
bundle id (`~/Library/WebKit/<bundle id>`, cookies in
`~/Library/HTTPStorages/<bundle id>.binarycookies`). Checked in a test copy
2026-11-25: a cookie with an expiry and a `localStorage` value set before the
copy was quit were both sent back after it was started again. So a sign-in
survives a relaunch, with two limits: a cookie with no expiry is gone when
the app quits, as in any browser, and a Debug build on its own bundle id
(`Wortel Dev`) has its own sign-ins. Not checked: whether 1Password fills a
form in the tab. That needs a person at the Mac.

**Downloads** (`BrowserDownloads`, one list for the app). A response a tab
can't show, one its server marked `Content-Disposition: attachment`, or a
link with the `download` attribute becomes a `WKDownload`
(`BrowserPage`'s two policy methods answer `.download`) and is saved to
`~/Downloads`. Nothing downloaded is opened, by the tab or by a click in the
list. The name is WebKit's suggestion made safe (`BrowserDownloadName`:
never hidden, never empty) and numbered as the Finder numbers a copy
(`report 2.zip`), so a download never replaces a file. A `file:` the tab
can't show is not a download: it is shown in the Finder. From a frame inside
a page only an attachment from the page's own host is saved
(`BrowserDownloadName.saves`), so a frame from another site can't put a file
in Downloads. The page itself can, without a click: Safari asks once per
site before that, Wortel does not ask (nothing is opened, and the file is
quarantined). A window a page opened itself
(`BrowserPopup`) has no navigation delegate and saves nothing.

The header of every browser tab has a downloads button once the list has
something in it (`DownloadsButton`), a ring filling while a download runs,
and a popover in the running-jobs popover's style: Show in Finder, Stop,
Clear. The list is memory only and empty after a relaunch; the files stay.
Progress is read by a quarter-second timer that exists only while something
is downloading, so a hidden tab's download costs a few property writes a
second and a redraw of whichever button is on screen.

Measured off screen 2026-11-25 (macOS 27.0): WebKit sets
`com.apple.quarantine` on the saved file itself, and hands over a file name
that is already one path component. A stopped download leaves its partial
file, so `BrowserDownloads.stop` removes it. A Debug build saves to
`WORTEL_DOWNLOADS_DIR` when that is set, for a test copy
(`BrowserDownloadsFolder`, read in `main.swift` before the launch scrub
removes every `WORTEL_` variable).

A file or browser opened without saying where goes where you last *moved* one
of its kind in that session, or dropped one from a list (`WorkspaceTabs.home(for:)`;
until then the main area for a file, the column for a browser). ⌥-click puts
it in the other place once (`elsewhere(for:)`: out of the main area, else into
it) without teaching that.

One file tab per session can be the **preview tab** (`WorkspaceTabs.peek`,
`Session.peekTab`, not persisted): a file looked at from Changes or Files,
with an italic title, which the next one replaces in place
(`showPeek`, through `GitPanelModel.showPeek` and `AppDelegate`'s `.peek`
placement); a double-click in the list opens it too. A double-click on the
file it already shows, in the list or on the tab (`keep`), moving it, or
Open in the row's menu
makes it an ordinary tab. It never opens in the row of the list it was
picked in (`peekRegion`), and a click follows only while a file is in
front there (`showsFile(in:)`).

A tab is in exactly one row; the one in front fills its area. Any tab goes in
any row, except the session's terminal, which never leaves the
main row and can't be closed. Opening a tab shows its row, closing the last
takes the column, the strip or a made split out of the tree (in one cut),
⌘⇧T reopens the last closed in the row you're in. All of those rules live in **`WorkspaceTabs`**, a pure value
with its own tests (`WorkspaceTabsTests`); `Session.workspace` reads the
session's individually-observed fields into it and writes back only what
changed, and `GitPanelModel` wraps each change with the side effects (the pane
shown, the keyboard, saving). Change a rule there, not in the model.

**One tree of splits** (`SplitLayout`, `WorkspaceTabs`, `TabRegion`,
`Wortel/UI/MainArea.swift`, `SplitTreeView.swift`, `SplitLeaf.swift`,
`SplitPane.swift`, `BottomStrip.swift`). On the branch `flexible-panes` since
2026-11-26, not released. It reversed "No splits", and the same day the side
column and the strip became splits too (`../../../docs/decisions.md`, the two
entries of that date). A person reads "split". The code says "pane" for a
split somebody made (`TabRegion.pane(id)`, `panes`, `PaneBar`,
`SplitPaneController`), which is not the glossary's pane, and "column" or
"side split" for the side column.

Everything beside the sidebar is a tree of rows and columns (`SplitLayout`, a
pure value with its own tests, `SplitLayoutTests`) whose leaves are rows of
tabs. There are four kinds of leaf and one set of rules for them:

- `.main`, the main row: the session's own terminal and what shares its row.
  Always there.
- `.side`, the side column: a leaf exactly while it has tabs.
- `.bottom`, the strip: a leaf exactly while it has tabs.
- `.pane(id)`, a split somebody made (`WorkspaceTabs.split`, around one
  tab), with its row in `panes[id]`.

Every `TabRegion` is a leaf (`TabRegion.leaf`). A session with nothing but
the main row has a tree of one leaf, and looks as it did before there were
splits.

**What was taken out on 2026-11-26.** The side column was a third pane of
the window's `NSSplitViewController`, and the strip a pane inside the middle
one (`TerminalWorkspaceController`). Each had its own sizing, collapsing,
animation and drop zones: the column's width captured in `viewDidLayout`, its
collapse, its holding priority that a browser in front could lower, the
strip's own height. All of it is gone, and so is the first version's
stand-in, where the tree view was told to leave the two leaves out
(`TODO(unify)`). `MainSplitViewController.ColumnWidth` and
`BottomPaneController.Height` are left, only as where the two start. A new
pane in the window's split view for something that holds tabs is the thing
that was taken out. Make it a leaf.

**Nothing is hidden** (since the afternoon of 2026-11-26;
`../../../docs/decisions.md` has the owner's reason). The column and the
strip could be hidden with their tabs kept, by ⌥⌘B and ⌘J. That is gone, and
with it the one state a leaf could be in that a made split could not.

- A row that holds a tab is on screen. `WorkspaceTabs.place` sets
  `sideVisible` or `bottomVisible` as it puts a tab in, and bringing a tab
  forward does too (`show`). Emptied, the leaf leaves the tree.
- `GitPanelModel` has no way to hide either: its `setVisible` and
  `isPresented` are gone. `isVisible` and `bottomVisible` still mirror the
  session, and now only say whether the row has tabs.
- **⌥⌘B** is `GitPanelModel.toggle`. With no pane in the column's row it
  opens Changes and Files there (not one that is already open in another
  split), brings the pane last used forward (Changes when that was History)
  and focuses it. With any of Changes, History or Files in that row it
  closes them (`putAway`), and the keyboard goes back to the main row, or
  stays in the split when something else is left in it. `toggleCloses` is
  what the menu item reads for its title.
- **⌃⌘1, ⌃⌘2, ⌃⌘3, ⌃⇧G** are `activate`. One rule, wherever the pane is: not open, it opens in the
  column's row; open behind another tab or behind a zoom, it comes forward
  where it is; on screen, it is closed by `putAway`, where the whole column
  used to hide (`git-panel.md`). Until later on 2026-11-26 a pane in the
  main row went behind the session's terminal with its tab kept, and one in
  a made split only came forward.
- **⌘J** is `toggleBottom`: no strip, a terminal is opened there; a strip,
  and you are not in it, its front tab is brought forward (which ends a zoom
  that covered it) and takes the keyboard; in it, the keyboard goes to the
  main row. Nothing closes.
- **A file from a build that could hide them** is mended once, as a session
  is read (`WorkspaceTabs.showHidden`, from `SessionManager.restore`, before
  `normalized`): the panes of a hidden column or strip are detached, and
  what is left (a terminal, a file, a page) is made visible, because a shell
  must not be out of reach. The flags are still written, for an older build.
- **What is left in the model and unused.** `sideVisible`, `bottomVisible`,
  `WorkspaceTabs.setVisible` and `hiddenLeaves`, and the `hidden` set that
  `SplitLayout.frames`, `moveDivider`, `neighbour` and `resize` take. Nothing
  in the app makes a leaf hidden after `showHidden` has run, so the set is
  empty everywhere it is passed (`SplitTreeView.apply`, `terminalSize(of:)`,
  the room check for `wortel split`). It is dead weight, not a feature to
  build on: bringing "hidden with its tabs kept" back is the decision that
  was reversed.

**What is still the side column's and the strip's.** Two things:

- **A place and a size to open at.** `WorkspaceTabs.keepFixedLeaves` puts in
  the leaf that is missing when its row gets a first tab, and takes out the
  one that emptied (`normalized` mends a file the same way). The side column
  goes to the outer edge of the whole tree
  (`SplitLayout.insert(_:atRootEdge:share:)`, the left edge when
  `sideLeading`), the strip directly under the main row. The model knows
  shares, not points, so both go in at a guess (a third of the width, three
  tenths of the main row's height) and are marked `unsized`, which is not
  saved. The window gives each its real size the first time it lays it out
  (`MainAreaController.sizeNewLeaves`, from `syncTree` and `viewDidLayout`,
  through `GitPanelModel.resizeLeaf` and `SplitLayout.resize`). For the
  column that is the session's width or the last one chosen anywhere
  (`MainSplitViewController.ColumnWidth`: 440pt to start with, at least
  260), and at most half the area. For the strip it is the height last
  chosen (`BottomPaneController.Height`: 240pt to start with, at least 100),
  and at most six tenths. Only for the session on screen and not under a
  zoom. From then on its size is a share like any other. A divider's drag that changes
  the column's width or the strip's height is remembered for the next one
  that opens (`MainAreaController.rememberSizes`, on the divider's release).
- **Their share when the others are made equal.** One more split among
  equal siblings, a split that closes, and `equalize` all leave the two the
  share they have (`SplitLayout.keepsItsShare`). Otherwise ⌃⌘= would hand
  Changes an equal part of the window, and a second ⌘D beside a column
  would make a quarter where it makes a third without one.

Everything else about the two is what every leaf does. The command that
moved the column to the other side (⇧⌥⌘B) and the drop that did the same
(the session's own tab let go on the column) are gone: Changes is put on the
left by dragging its tab there, which makes a split of its own.
`WorkspaceTabs.setSideLeading` and `GitPanelModel.setColumnLeading` are
still there, and `sideColumnLeading` still says which outer edge the column's
leaf is made at. One thing calls them, the probe's `swap` step: no command or drag in
the app changes the side any more.

The model:

- A leaf other than the main row is there only while it has tabs. Closing or
  moving out its last one takes it out of the tree, and its room goes to its
  siblings. Nothing is placed in a made split that isn't there. A tab put in
  the column or the strip makes its leaf.
- Sizes are weights, everywhere, so a window resize keeps every split's
  share, the column's and the strip's too: Changes grows with the window.
  Until 2026-11-26 the column kept its width and the terminal took the whole
  change. Points only exist in `SplitLayout.frames(in:)`, on whole points,
  with no split under its minimum (160 by 100, `Metrics.minimum`) while
  there is room.
- A divider's drag changes only the two parts beside it, neither under its
  minimum (`moveDivider`). So dragging a divider to the edge closes nothing,
  where it used to close the column and the strip.
- Siblings that were equal stay equal when one more joins: a second split
  right is three thirds. After a divider has been dragged, a new split halves
  only the one it came from (`SplitLayout.insert`).
- A split is made beside the leaf it is asked about, the column and the
  strip included. Asked about one that has gone, it is made beside the main
  row.
- One leaf can be zoomed (`zoomed`, not saved): shown alone, the others kept.
  Any leaf that is on screen, while there is more than one. Bringing a tab
  forward in another leaf (which is what ⌥⌘B and ⌘J do) or splitting ends
  it. Except a split
  made by `wortel split` (`keepsZoom`): the zoom stays and the new split is
  behind it.
- **Reset Layout** (View menu, no key; `WorkspaceTabs.Preset`,
  `arranged(as:keeping:)`, since 2026-11-26). A pure function from one
  `WorkspaceTabs` to another: the same tabs in the arrangement of a preset.
  There is one preset, `.standard`, the arrangement a session starts in.
  The main row keeps its tabs in order and takes every other terminal and
  file, in reading order. The column's row keeps its panes and browsers and
  takes every other pane and browser (`goesBeside`). The strip, every made
  split, the zoom and the habits are left out of the new value, and
  `normalized` builds the tree from the two rows, so the column's leaf is
  there only if its row has tabs and comes back `unsized`, to be given its
  usual width by the window. Nothing is closed: every tab of `allTabs` but
  the empty ones is in one of the two rows. `sideLeading` and the closed
  tabs' stack are carried over. The tab passed as `keeping` (the one in
  front of the split you were in) is in front of the row it lands in, and
  each row's own front stays when it is still in that row.
  `GitPanelModel.resetLayout` wraps it like any change (mirror, save, the
  repo, the keyboard to the row `keeping` landed in), with no animation.
  `canResetLayout` dims the menu item unless there is a zoom, any split
  at all, or a main row that would change. Any split, so that a session
  that only had a divider dragged can be reset: the size a split opens at
  is the window's to know, so with the one split already as it opens the
  item is on and does nothing. A second
  preset is a case of `Preset` and a branch in `arranged`. It cannot be
  undone, which is why it has no key (`../../../docs/decisions.md`).
- The session's terminal never leaves the main row, and a split's only tab
  can't be split off its own split.
- `Session` holds it as `splitLayout`, `paneTabs`, `zoomedRegion` and
  `unsizedLeaves`, beside the column's and the strip's own rows and flags.
  `Session.allTabs` is every tab in every row: what closing a session, the
  process roots and the browser lookups go through.
- `GitPanelModel` mirrors those (and `hiddenLeaves`, `unsizedLeaves`) and
  adds `split`, `splitDropped`, `splitFromCommand` (`wortel split`: a split
  beside the main row of any session of the window, on screen or not, that
  takes no keyboard and is no stop on Back's trail; `../cli.md`),
  `toggleZoom`, `equalizeSplits`, `resizeLeaf` and `markLeafSized`,
  `setColumnLeading`, `roomToSplit` (the window's answer, asked before a split made
  by a key or a menu, to where its room comes from: the split itself when
  it is big enough to be two, the whole row or column it is in when it
  isn't but that is, `SplitLayout.insertSpreading`, or nowhere, which is the
  system's sound; `MainAreaController.room`), and for a divider's drag `setSplitLayout` (every step,
  writes the layout only) and `commitSplitLayout` (once, saves).
  `currentLeaf` is the leaf a command without a target acts on: the one you
  last worked in while it is in the tree and on screen, else the main row.
  `lastRegion` never answers with a split that has gone or that a zoom
  hides. `keyRegion` is the same answer, read so that a row follows it.
- Saved as `splitLayout` and `paneTabs` in `sessions.json`. The tree is
  written whenever it is more than the main row, so a session with a column
  or a strip writes it. `paneTabs` is left out while there are no made
  splits. `sideTabs`, `bottomTabs`, `gitPanelVisible`, `bottomVisible`,
  `sideColumnLeading` and `sideColumnWidth` are saved beside the tree as
  they always were, which is what an older build reads. Both new fields are
  read leniently: a tree that can't be read is no split, and
  `WorkspaceTabs.normalized` puts the tabs of a split with no place in the
  tree into the main row, so a terminal's shell is never left without a tab.
  A file with no tree, or a tree without the column's or the strip's leaf,
  gets each put where it opens, `unsized`, so it comes up at the session's
  saved width.
- Three kinds of older build. The released app drops both fields and saves
  without them: the column and the strip are as they were, and a made
  split's terminal is then a shell in the keeper that no session claims,
  which the next launch treats as any unclaimed shell
  (`SessionManager.recoverOrphanedShells`): closed when it sits at a prompt,
  brought back as a session of its own when something runs in it. The first
  version's build of this branch (`de5808e`) cannot read a tree with a
  `side` or `bottom` leaf and reads it as no split, the made splits' tabs
  going to the main row. Read from the code, 2026-11-26, not tried.
- The window's split view autosaves under `window-split`, not `main-split`:
  it has two panes where it had three, and builds share the defaults. The
  sidebar's width is carried over from the old name once
  (`MainSplitViewController.startingSidebarWidth`).

The views:

- **One flat view** (`SplitTreeView`, the view of `MainAreaController`).
  Every leaf's view is a direct subview whose frame is set from
  `SplitLayout.frames`, with a divider view over each gap. Not split views
  inside split views: a split that comes, goes or moves to another edge
  never takes another one out of the window, and a terminal that left the
  window would have to be shown again. A session switch hands over another
  tree and nothing is rebuilt. Nesting `NSSplitView`s is the trap.
- **One kind of leaf** (`SplitLeafView`): a row on top and a page under it.
  The row is a `LeafBar`, a `ChromeBarView` with a `strip` of tabs, a
  `leadingClearance`, a `trailingClearance` and an `unzoom` button. One
  class conforms, `PaneBar`: the tabs, "+" right after the last, and
  nothing else but the button that shows while its split is zoomed. That
  button takes no room while it is hidden (`ZoomedButton`: its width is 0
  then, and the strip runs to the row's end). The "+" (`PaneBar.addTab`)
  opens an empty tab in that row (`GitPanelModel.openBlank`). It has no
  menu and no right-click menu: `NewTabMenu` is deleted. Every leaf has
  one, wired the same way
  (`PaneBar.wire(to:home:region:)`). There were four until 2026-11-26:
  `MainBar` showed the session's name as a plain title until the row held
  more than the terminal and carried the session's "…", what it runs and
  the column's toggle, `SideColumnBar` carried the toggle, `BottomBar` a
  chevron that hid the strip. Those buttons are the window's now, at the
  trailing end of the titlebar (`WindowControls`,
  `window-and-sidebar.md`), or a key (⌘J for the strip). The reason is in
  `../../../docs/decisions.md`: on a row, they ended up in the middle of the
  window once a split could sit to the right of it. A button of a row's own
  is the thing not to add back.
- **The main row always shows its tabs.** The session's terminal is the tab
  `SideTab.session`, titled with the session's name and `pinned`
  (`TitleBarController.stripItem`): `SideTabView` hides its close button and
  gives it no menu, and `SideTab.fits` keeps it in the main row. A session
  with only its terminal shows that one tab. `TitleBarController` still
  holds the main row's and the side column's bars (`mainBar`, `sideBar`,
  both `PaneBar`) and fills their strips (`syncColumn`); `MainAreaController`
  wires them.
- **A row short of room gives way in a fixed order** (`SideTabStrip.plan`).
  Each tab starts as wide as its title, up to 240pt. When they do not fit:
  first every tab behind the one in front, the session's pinned tab aside,
  gives up the room it keeps after its title for a close button
  (`SideTabView.canHug`, `huggingWidth`, `isHugging`). Such a tab ends 6pt
  after its title, and its close button shows over its glyph while the
  pointer is on it, as Safari's does. Then the tabs that still can shrink
  together, down to 130pt or their title, whichever is less. Only then does
  the row scroll, with "+" pinned past the visible end. The first step is
  from 2026-11-26: it is what lets Changes and Files both keep their names
  in a 440pt split under the window's buttons (there were six that day). The session's own tab
  never keeps that room at all, since it is never closed (`b7675b2`).
- **The empty tab** (`SideTab.blank(id)`, `Wortel/UI/NewTabPage.swift`,
  since 2026-11-26). A tab that is nothing yet, titled "New Tab". A row's
  "+" opens one at the end of its row, in front (`openBlank`), and a row
  that already has one brings it forward instead of making a second. The
  titlebar's split buttons make a split around one. Its page is
  `NewTabPage`, drawn by `TabContent` like any page that is not a
  terminal: five rows, Terminal, Browser, Changes, History, Files, each
  with the key that opens the same thing without asking, Changes with its
  count. A click on a row, or the arrows and Return, calls
  `GitPanelModel.fill(_:with:)`: the split becomes the one you are in, the
  new tab is opened there in front (`NewTabChoice`; a pane that is open in
  another split is moved, as `open(_:in:)` does), then the empty tab is
  closed, then the front tab is focused. In that order on purpose: closing
  first would take a split whose only tab was the empty one out of the
  tree before there was anything to put in it. Escape closes the empty tab
  (`requestClose`). The page takes the keyboard when it appears in the
  split you are in, and `settle` takes it from a terminal the empty tab
  covers (`onClearKeyboard`), so nothing is typed into a terminal that
  cannot be seen. It is in no row's habits (`kind` is nil) and is not
  counted as a tab opened (`TabOpenedKind`): what it becomes is. It is
  saved as `"new:<uuid>"` with the other tabs, so it is back after a
  relaunch, and a build from before it reads that as no tab and drops it.
  Why it exists is in `../../../docs/decisions.md`: a menu on "+" was two
  clicks with nothing on screen between them, and buttons in the titlebar
  for each thing opened it in one place only.
- **The row has two looks, by where the tree put the leaf.**
  `MainAreaController.placed` runs after every layout and sets
  `SplitLeafView.isAtTop` for each leaf on screen (its frame starts at the
  top of the tree). Along the top the row is a titlebar row
  (`ChromeBarView.isTitlebar`): the titlebar's height, see-through to the
  window's glass, a hairline under it, the tab in front raised off the band,
  and its empty part moves the window. Lower down it is the strip's kind of
  row: 36pt (`SplitLeafView.rowHeight`) on `Chrome.stripBand` over the page,
  no hairline, the tab in front in the page's colour (`strip.isOnPage`), and
  a double-click on its empty part zooms the split (`onRowDoubleClick`). A
  leaf changes look when it changes place: a zoomed strip fills the area, so
  it is along the top and has a titlebar row. This is why the terminal with
  Changes beside it has both rows in the titlebar, as when the column was a
  pane: both are along the top. The first version gave every split a 36pt row under a
  titlebar that showed the session's name. That is gone.
- **The pages.** The main row's (`mainBody`) is the session's terminal and
  what covers it, as before. The side column's is `SideColumnController` and
  the strip's `BottomPaneController`, the same controllers as when they were
  panes, minus everything about their size. Those three leaves always have
  views, shown or not. A made split is a `SplitPaneController`, one per split
  id, kept for as long as any session has that split and hidden (never
  removed) while it isn't on screen. Each keeps its terminals in a
  `SideTerminalHostController`, and its page is `TabContent` in a hosting
  view with `sizingOptions = []`.
- **Who makes room for the window's controls.** `MainAreaController`
  lists the rows along the top with where each starts and ends
  (`titlebarRows`), and `MainSplitViewController.updateLeadingInsets` gives
  each a `leadingClearance` (for the sidebar's toggle and the arrows, more
  than nothing only for the leftmost) and a `trailingClearance` (for the
  session's controls, only for the rightmost). A row that is not along the
  top has neither (`SplitLeafView.dress`).
- **Dimming** (`MainAreaController.dressRows`). With more than two leaves on
  screen, the tab in front of a row you are not in has the secondary label
  colour (`SideTabStrip.isKeyRow`), the main row's like any other. With one
  or two, nothing is dimmed. `dressRows` is the one place that writes
  `isKeyRow`, for every row. A made split's controller wrote it too at
  first, without the count, and the two could disagree.
- **Dividers** are the 1pt gap in `Chrome.hairline`, taking presses 4pt
  either side. A drag moves the divider in the view's own copy of the layout
  (`SplitLayout.moveDivider`), so the split follows the pointer in the same
  event. A double-click equalizes the whole tree, as ⌃⌘= does.
- **One cut, except the side column and the strip opening.** A split
  somebody makes or closes, a zoom, a divider's double-click, a session
  switch, and the column or the strip going each land in one cut, so a
  terminal gets one new size.
- **The slide** (`SplitTreeView.apply(layout:zoomed:hidden:slides:)`).
  ⌥⌘B and ⌘J slid while the column and the strip were AppKit panes, and
  opening still does: the tree moves the leaves itself.
  `MainAreaController.slides` asks for it only when the set of those two on
  screen changed, in the same session, with no zoom before or after, and
  the model says the change was by hand
  (`GitPanelModel.animatesVisibilityChange` for the column,
  `animatesBottomChange` for the strip). Since nothing is hidden, the only
  change by hand that sets them is a tab opened there: ⌥⌘B opening Changes
  and Files, ⌘J making the strip, a tab moved in. A column or strip goes
  only because its last tab closed, and that cuts: ⌥⌘B putting Changes and
  Files away closes their tabs first, and a slide would be of an empty
  page. The view can still slide a leaf out (`leaving`, `Motion.closing`),
  and nothing asks it to. Anything a session switch changes cuts too. The view
  slides only when a leaf really comes onto the screen or leaves it. It
  then steps every leaf's real frame from where it is to where it goes, on
  a timer at 120 a second in the common run loop modes, for `Motion.opening`
  (0.26 s) or `Motion.closing` (0.18 s), along `Motion.curve` (worked out in
  `ease`). Real frames, a step a frame, as AppKit's own split view steps a
  pane open. Around it:
  - Resizes are held for all of it (`SurfaceView.holdResizes`) and let go a
    turn after it lands, when the frames are final. The terminal beside the
    one sliding is resized once.
  - The dividers are hidden for its length.
  - `onPlaced` runs before anything moves, so every row has the look of the
    place it will end in (`isAtTop` is read from the layout, not from the
    frames in between).
  - The leaf coming or going starts from, or ends at, nothing: squeezed
    against the edge it shares with the neighbour that makes room for it
    (`collapsed`).
  - A slide is landed at once by another `apply` that changes something, by
    the tree's own size changing under it (`layout`), and by `placeNow` (a
    session switch). While one runs, `layout` leaves the frames alone.
  `Motion.pane` is still the sidebar's alone: that one is AppKit's pane.

Making one, and dropping on one:

- ⌘D and ⇧⌘D (`AppDelegate.splitRight`, `splitDown`) put a new terminal in a
  split beside the leaf you're in (`GitPanelModel.currentLeaf`). From Changes
  that is a split beside Changes, from the strip one beside the strip. The
  two buttons at the trailing end of the titlebar (`AppDelegate.newSplitRight`,
  `newSplitDown`) make the same split with an empty tab in it, where the
  keys put a terminal: a key says what it wants, and a button is pressed by
  someone still deciding. Split Right and Split Down in a tab's own menu
  move that tab into a split (`SideTabStrip.onSplit`). The session's "…"
  and a row's "+" have no split items. All of them go through the same
  `GitPanelModel.split`, which asks the window
  where the room comes from (`roomToSplit`, `MainAreaController.room`). A
  leaf that is two minimums and a gap wide (or high) is halved. One that is
  not takes the new split's room from the whole row or column it is in, an
  equal share from every part (`SplitLayout.insertSpreading`): ⌘D in a side
  column 280pt wide did nothing before that. Only when that row has no room
  either do they beep and do nothing. A command teaches no habit
  (`home(for:)`); a drop does.
- The rows a drag can land in all come from `MainAreaController.rows`: every
  leaf on screen, the main row among them. Until the main row always showed
  its tabs it was a static entry of its own, with a drop slot standing in
  for the hidden strip beside the title (`MainBar.dropSlot`). That is gone.
- A drag is resolved by `TabDragController`: first the rows
  (`stripLanding`, to reorder or to land at an exact place in another row),
  then the splits (`zoneLanding`, `paneLanding`). `SplitLayout.dropEdge`
  gives each edge of a leaf a band a quarter of it deep, 32pt at least,
  160pt at most and never over a third. In a band the drop is a new split on
  that edge, and what lights up is the half of the leaf on that side with a
  line where the two will meet (`MainAreaController.paneDrop`). In the
  middle it moves into the leaf, and the whole leaf lights up. No words on
  either: the owner tried "Move Here" and "Split Right" over the tint and
  found the tint and the line enough (2026-11-26). The half is not the
  frame the split ends up with (a third among two equals): that was shown
  for a morning and lay across two splits, which read as a mistake.
- That holds for every leaf. Until 2026-11-26 the area's own edges stood for
  "open the column", "move the column over" and "open the strip", each with
  a label of its own. Those zones are gone. The session's own tab fits no
  row but its own and is never split off, so over any other split it lands
  nowhere. (It traded sides with the side column when let go on it, `.swap`,
  until the afternoon of 2026-11-26.)
- A leaf too small to be two has no edges, only a middle. A split's only tab
  dropped on its own edge lands nowhere, and so does a tab let go on the top
  edge of its own split. Nor does a drop that would move nothing: a split's
  only tab on the edge of a neighbour that it already sits against closes
  its split and makes one in the same place, so nothing lights up
  (`changesSomething`, which asks `WorkspaceTabs.split` on a copy).
- A file out of Changes or Files lands the same way,
  the first file making the split and the rest opening in it. Over a
  terminal the drop stays the terminal's, which types the path.

The keyboard:

- ⌘] and ⌘[ walk `visibleRegions`: the tree's leaves that are on screen, in
  reading order. The column and the strip come where their leaves are.
- ⌃⌥⌘ and an arrow (`focusArea`) and ⌃⌘ and an arrow (`moveFocusedTab`) both
  ask `neighbouringArea`: the leaf across that edge that shares the most of
  it (`SplitLayout.neighbour`, the upper or left one on a tie). With no leaf
  there, focus stops. A moved tab has one more answer: toward the edge the
  column opens on it goes to the column, and down to the strip, when that
  one has no tabs, which makes it. The session's own tab goes nowhere.
- A click in a split makes it the area you're in
  (`MainSplitViewController.region(at:)`), so ⌘T, ⌘W, ⇧⌘T and ⇧⌘L act there.
  Two places answer nil, so a press there leaves you where you were: a
  divider, and any of the window's controls (`WindowControls`), which lie
  over the end of whichever row is under them. Without the second, a press
  in the corner would move you to the split under it first.
  Closing the split you're in sends the keyboard to the main row, or to
  whatever is zoomed.
- Zoomed (`toggleZoom`, ⇧⌘↩, a double-click on a row that is not in the
  titlebar), the tree view gives one leaf the whole area and hides the rest.
  ⇧⌘↩ from the column or the strip zooms that one. The hidden rows answer
  nil to `activeTab(in:)`, and the main terminal behind a zoomed split
  counts as covered, so it gives up the keyboard
  (`keepKeyboardOffCoveredTerminal`). Showing all of them again leaves you
  where you were: `TerminalHostViewController.viewDidAppear` takes the
  keyboard the first time only (it also runs each time the main row comes
  back from being hidden), `toggleZoom` keeps the area it read while the
  zoom was on, and `onFocusMainTerminal` lays the main area out first when
  the change that sends the keyboard there has also just ended the zoom
  that hid it.

Known limits:

- A terminal in any split but the main row is a side terminal. Agent
  tracking, naming and resume follow the session's own terminal only.
- A split holds tabs, never another session.
- A side terminal is never hibernated: `HibernationPolicy` is only told
  about a session's own terminal.
- A made split that emptied is hidden at once and leaves the window half a
  second later (`MainAreaController.syncTree`): a terminal moved out of it
  as its last tab is in its old host until the row it went to has shown it.
- A column or a strip that was opened in a session out of sight, and never
  shown before the app quit, was saved at its guessed share: `unsized` is
  not saved, so it comes back at a third of the width, not the session's
  width. Read from the code, not tried.

A session out of sight and a window resize. Its terminal follows the window
once the resize ends (`SurfaceView.followWindow`), and that used to be "by as
much as the window changed", which was right while the panes beside it kept
their width. With shares, a terminal beside a side column takes only part of
the change. So the app is asked instead (`SurfaceView.sizeWhenShown`, set in
`AppDelegate`): `MainAreaController.terminalSize(of:)` lays the session's own
tree out in this window as it is now (with that session's hidden leaves,
of which there are none since nothing is hidden), and
answers with its main row's page (the leaf less its row, a titlebar row along
the top and 36pt lower down). It answers nothing when the main row is behind
a zoom on another split, or the terminal is in no window of ours. Then, and
only then, the old sum is used. A new leaf kind, or a row of another height,
has to be right in `terminalSize` too, or hidden sessions are told a size a
few points off.

`scripts/try-splits.sh` is the test. It runs a throwaway copy of a Debug
build, and `SplitProbe` in it (there only with a data folder of its own)
makes the splits by the actions the menu sends, lets go of a tab
through the drag's own resolver (`drop:<n>.<where>`), and writes down each
split's frame and tabs, each terminal's view against its split and against
the size it was told, and who has the keyboard. Checked with it 2026-11-26,
macOS 27.0, on the build with one tree: the side column alone (the picture
is the window as it was before splits), hidden and shown (back at 440pt),
the strip likewise (240pt), splits of the main row, of the strip and of the
side column, a zoom, focus by direction across all of them, a divider drag,
equalize, a window resize (`resize:<w>x<h>`), a session switch and back,
drops on an edge and into the strip, the side column moved to the left with
the sidebar collapsed (`swap`, `sidebar`), and a relaunch: 0 faults.
`scripts/try-switch.sh --side --widths` the same day: 0 of 72 returns wrong.
`SwitchProbe` reads the side column's leaf from `SplitTreeView` now and
drags the divider beside it. All of that was before the slide, the exact
size for a session out of sight and the one owner for dimming went in. After
them, the same day: `try-splits.sh --relaunch column column column strip
strip strip right down zoom zoom column column resize:900x560 next next next
strip strip`, 0 faults, and the five splits back after the relaunch. The
script now deletes its copy's defaults before each run: they go by bundle
id, and a sidebar an earlier run had hidden started the next run hidden. Not
run again after those changes: `try-switch.sh --side --widths`, and the rest
of `scripts/check-terminals.sh`, which was not run on the build with one
tree at all. After nothing could be hidden any more, the same day:
`try-splits.sh --relaunch column column column tab column column strip strip
strip zoom zoom`. ⌥⌘B opened Changes and Files at 440pt, closed them (the
split gone, the keyboard in the main row) and opened them again; with a
terminal tab added to that split it closed the two panes and left the
terminal and the split, and opened them again; ⌘J made the strip, went back
to the main row, went to the strip; a zoom and back; 0 faults, and the three
splits back after the relaunch. WortelTests pass, with three expectations
changed to "on screen from the moment it holds a tab" and one new test for
`showHidden`. The earlier lists above say "hidden and shown": that was the
build that could. Not checked: a drag with a real pointer, several windows
with splits, and the look by eye, which nobody has given the last change.

Things that look like detours and aren't:

- **Terminals are never rebuilt when they move.** Side terminals (`sideSurfaces`
  on the session, keyed by tab id, which is also their keeper id so they
  survive a relaunch) live in always-mounted hosts (`SideTerminalHostController`)
  that hide rather than remove; moving a terminal between rows is `addSubview`
  into the other host. The session's own terminal stays mounted in the main
  area and a pane in front of it is a cover that takes the keyboard away from it.
- **A terminal's host is never inside a SwiftUI view.** All five places a
  terminal can be (the session's own pane, the main row, the side column,
  the strip, a made split) are AppKit controllers that size the host
  themselves, with SwiftUI's page in a view of its own on top, hidden or
  taking no clicks while a terminal is in front. Since 2026-11-26 all five
  sit in leaves of the one tree, and they are still five controllers:
  `TerminalPaneController`, `MainAreaController`'s own host,
  `SideColumnController`, `BottomPaneController`, `SplitPaneController`. Inside a representable it is SwiftUI
  that places the host, and SwiftUI can be a layout behind: the session's
  terminal ran under the side column that way (`TerminalPaneController`,
  `../../../docs/decisions.md` 2026-11-19). A hosting view pinned to a pane
  takes `sizingOptions = []`, or an empty page asks for no height and takes
  the pane with it. `scripts/try-switch.sh` is the test.
- **The titlebar tabs are NSControls and the window is `isMovable = false`.** The
  window server moves a window from any press in a transparent titlebar that
  isn't on a control, whatever `mouseDownCanMoveWindow` says; the rows start
  window drags themselves (`performWindowDrag`) from their empty space.
  `WindowMovability` turns it on only while fn-⌃ is held, a menu is open
  or the pointer is outside the window, so tiling still works. Not by where
  the pointer is in the window: the app can hear that late or not at all, and
  the window server doesn't wait for it (`WindowMovabilityTests`).
- **Sidebar commands are Wortel's own** (`toggleSessionSidebar:`), not AppKit's
  `toggleSidebar:`: SwiftUI's hosting views answer that one on its way up the
  responder chain and swallow it.
- **Terminals don't resize during a pane's animation** (`Motion.pane`,
  `SurfaceView.holdResizes`): one resize when it lands instead of one a frame,
  each of which made the program inside redraw. Since 2026-11-26 two things
  animate: the sidebar, which is AppKit's pane (`Motion.pane`), and the side
  column and the strip, which are leaves that the tree slides itself and
  holds resizes for in the same way (`SplitTreeView`, above). A terminal is
  never told a size under 40×20pt, which a pane or a leaf closing passes
  through. A session
  switch holds resizes too, while the tree takes the new session's frames
  (`MainSplitViewController.show`, `MainAreaController.applyNow`).

Where the two start: the column's width is per session (`sideColumnWidth`),
or the last one chosen anywhere, and the strip's height is app-wide. Both are
only where the leaf opens. After that each is a share of the area, and there
is no longer a rule that the column may grow until the terminal has 320pt:
the minimum of any split is 160 by 100. Tab drags are resolved by
`TabDragController` against the rows and against each split on screen (its
edges and its middle), each only for tabs allowed there. A file tab can also leave the window: past its edge the
ghost becomes a small window that follows the pointer (`TabTearOffGhost`, a
borderless panel, since the overlay is clipped to the window), and letting go
there opens the file in a preview window at that spot. The way back is
`handleDock`: a preview window dragged by its row over a tab row (rows only,
not the zones) fades out, the tab it would become shows in the row, and
letting go makes it. The window server still moves the window, so the window
watches the pointer on a common-modes timer until the button is up.

With several windows (since 2026-11-19), a file or browser tab dragged out of
one window over another window's row shows there, the same way a docking
preview window does (`TabDragController.elsewhere`, answered by
`AppDelegate.tabDragElsewhere` through `MainSplitViewController.dock`), and
letting go moves it into that window's session: `openDropped` there, then
`GitPanelModel.handOver` here, which takes it out of this session's rows
without closing it (no `onTabClosed`, nothing on the reopen stack), so a page
keeps its web view and a file its document. A browser's address goes with it.
Terminals and panes stay in their window: a side shell belongs to its
session's folder, and within one window a tab never changes session either.
Over another window that is in front of this one, even inside this window's
frame, the drag is that window's. A file out of a list is offered to the
window it is over the same way (`AppDelegate.fileDrag`). Side
terminals' processes count as the session's (`processRoots`); agent tracking, naming and
resume follow the main shell only.
