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
from an empty tab's page or ⇧⌘B, or on a server from the running-jobs
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

What is watched (`BrowserPageWatch`) is the page's file and up to 32 of the
local paths its markup names, each with its folder, and only what is a file
or a folder or isn't there yet. A page can name a FIFO or a serial port
(`<link rel=canonical href=/dev/tty.Bluetooth-Incoming-Port>`), and `open`
on one never returns: until 2026-11-27 that froze the app, and again at
every launch, since the tab's address is saved. `DirectoryWatcher` now
stats first and opens with `O_NONBLOCK`. A folder deleted and made again
(`rm -rf dist`, a rebuild) is waited for on the nearest folder above it
that exists, and watched again when it is back; a reload makes again any
watch that died.

**Mark-up** (⇧⌘M, the last button in the header) is in `mark-up.md`: its
layer lies over the web view inside `WebViewContainer`, it turns the swipe
back off and holds the reload-on-change while it is on, and any navigation
ends it (`BrowserPage.endMarkup`).

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
(`BrowserDownloadName.saves`), and a `download` link only when the frame it
is in is on the page's own host (`savesLink`: the frame counts, not where
the link points), so a frame from another site can't put a file in
Downloads, by a response or by clicking its own link from script. The page
itself can, without a click: Safari asks once per
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
file, so `BrowserDownloads.stop` removes it.

A download is written as `report.zip.download` and renamed to `report.zip`
in `downloadDidFinish`, so a quit, an update's restart or a crash leaves a
file whose name says it is not whole; until 2026-11-27 it left a truncated
`report.zip`. Measured off screen that day: the quarantine is on the file
by `downloadDidFinish` and the rename keeps it. The rename is `renamex_np`
with `RENAME_EXCL`, so it never replaces a file, and is numbered past a name
taken meanwhile. A name counts as taken while a running download holds it,
not only once it is on disk: WebKit makes the file a moment after it is
given the name (not there 50 ms later) and fails when the destination
exists, leaving that file alone. Two downloads of one name were both given
it, the second failed, and its cleanup deleted the first's file. A held
name is the download's and its `.download`'s, compared ignoring case as
the disk does. A download's cleanup removes only the exact `.download`
address it was given (`Item.partial`, `BrowserDownloadName.removePartial`),
and a server's suggested name loses a `.download` ending
(`BrowserDownloadName.cleaned`), so no download's own name can be another
one's unfinished file.

A Debug build saves to `WORTEL_DOWNLOADS_DIR` when that is set, for a test
copy (`BrowserDownloadsFolder`, read in `main.swift` before the launch
scrub removes every `WORTEL_` variable).

**Where a thing opens when nothing says where** (`WorkspaceTabs.home(for:)`):
a file in the main row, and everything else you look at beside your work in
the column's row, a browser like Changes, History and Files. That is the
whole rule since 2026-11-26. ⇧⌘B follows it too (`AppDelegate.newBrowserHere`
asks `home(for:)`): it opened its browser over the tab you were in, the one
of ⇧⌘C, ⇧⌘H, ⇧⌘F and ⇧⌘B that did. ⌥-click puts a file or a server in the
other place once (`elsewhere(for:)`: out of the main row, else into it). To
have a thing in a split of your choosing you say so: that split's "+", a
split button on a row, ⌥⌘T and its letter, or a drag.

Until that date there was a memory. A file or a browser opened where you had
last *moved* one of its kind in that session, or dropped one from a list
(`habits`, `learnHome`). It was taken out on the owner's instruction: where
the next one opened depended on something done a while ago, and a browser
followed a rule no pane had. The released app still has it. What is left of
it in the code is inert: `WorkspaceTabs.habits` is neither read nor written
and stays so that a saved session still decodes, and the `recordsHabit`
parameters of `move`, `split` and their callers do nothing. Do not read
either as a rule. The preview tab is not this: a file looked at from a list
goes where the preview tab is (`peekRegion`), which is that tab's place and
not a memory of where files go.

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
`SplitPane.swift`, `BottomStrip.swift`). Since 2026-11-26, on `main`, not in a
release yet. It reversed "No splits", and the same day the side
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
  and focuses it. With any of Changes, History or Files in that row, and
  that split on screen, it closes them (`putAway`), and the keyboard goes
  back to the split you were in before (`regionBefore`), or stays in the
  split when something else is left in it. `toggleCloses` is that test, for
  the key and for the menu item's title alike. Behind a zoom on another
  split the column is not on screen, so ⌥⌘B takes the open path: the panes
  come forward and the zoom ends, as ⇧⌘C does. It used to look only at
  whether the row held a pane, and with the main row zoomed it closed
  Changes and Files nobody could see.
- **⇧⌘C, ⇧⌘H, ⇧⌘F, ⌃⇧G** (and ⌃⌘1, ⌃⌘2, ⌃⌘3, what the first three were until
  2026-11-26) are `activate`. One rule, wherever the pane is: not open, it opens in the
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
  is read (`WorkspaceTabs.showHidden`, from `PersistedSession.restoredTabs`,
  before `normalized`): the panes of a hidden column or strip are detached, and
  what is left (a terminal, a file, a page) is made visible, because a shell
  must not be out of reach. The flags are still written, for an older build.
- **What is left in the model and unused.** `sideVisible`, `bottomVisible`
  and `hiddenLeaves`, and the `hidden` set that
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
  tenths of the main row's height) and are marked `unsized`, which is saved
  (`unsizedLeaves`, below). The window gives each its real size the first
  time it lays it out
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
`sideColumnLeading` (`WorkspaceTabs.sideLeading`) still says which outer edge
the column's leaf is made at, and a session saved with it on the left keeps
it there. Nothing in the app changes it any more: the functions that did
(`setSideLeading`, `setColumnLeading`) and the probe's `swap` step were
removed before the merge to main.

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
  split and the zoom are left out of the new value (and the unused `habits`
  field with them), and
  `normalized` builds the tree from the two rows, so the column's leaf is
  there only if its row has tabs and comes back `unsized`, to be given its
  usual width by the window. Nothing is closed: every tab of `allTabs` but
  the empty ones is in one of the two rows. `sideLeading` and the closed
  tabs' stack are carried over. The tab passed as `keeping` (the one in
  front of the split you were in) is in front of the row it lands in, and
  each row's own front stays when it is still in that row.
  `GitPanelModel.resetLayout` wraps it like any change (mirror, save, the
  repo, the keyboard to the row `keeping` landed in), with no animation.
  The menu item is on whenever there is a session
  (`AppDelegate.validateMenuItem`). It was dimmed when there was nothing to
  put back (`canResetLayout`, gone), and a dimmed item is not in the
  command palette at all, which lists only enabled items: the owner looked
  for it and could not find it. With nothing to put back it does nothing.
  It has an icon in the palette (`PaletteCommands`). A second
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
  `roomToSplit` (the window's answer, asked before a split made
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
  `paneTabs` is decoded one split at a time (`LenientPaneTabs`), so one
  value that cannot be read costs that split and not the others. A split
  whose key is no id still has tabs, a terminal among them perhaps: it is
  given a fresh id, which no leaf names, and so folds into the main row.
  Restore is one pure function, `PersistedSession.restoredTabs(panelVisible:defaultPane:)`,
  which `SessionManager` and the tests both call: a test of restore that
  builds its own steps can assert a state restore never makes, and two did.
  And a divider's drag never stores a weight of zero
  (`SplitLayout.moveDivider`, `resize`, `setWeights(of:shown:from:laidOut:)`):
  a part the move changes that would get no room at all is not written,
  since a zero is what `tidied` reads as a damaged file and turns into
  equal shares. The other half matters as much: a part the move does not
  change, laid out at 0pt, keeps the weight it had, and the rest share what
  is left. Its 0pt is only rounding, in a row squeezed under its minimums.
  The first form of this rule refused a move whenever any part of the
  split was at 0pt, and one sliver rounded to nothing stuck the divider
  between the other two until the window grew
  (`testASliverRoundedToNothingDoesNotStickTheOtherDividers`).
  A file with no tree, or a tree without the column's or the strip's leaf,
  gets each put where it opens, `unsized`, so it comes up at the session's
  saved width.
  `unsizedLeaves` is saved beside the tree (since 2026-11-27): the leaves
  still at their guessed share (`PersistedSession.savedUnsized`), read
  back as `unsized`, and left out when there are none. Only the session on
  screen is ever sized (`sizeNewLeaves`), so after an upgrade from a
  release without the tree every other session had its column and strip
  at the guess, and with nothing saying so, one save made that a share
  somebody chose: the column came back at a third of the window for good,
  not at its width. A build that doesn't know the field (`main` before
  that day) reads the guess as chosen, which is what it did anyway, and
  saves without it. Read leniently, as the tree is: a value that is not a
  list is no guess, and a name that is no leaf of the tree is dropped
  (`PersistedSessionTests`, `testAColumnNobodyHasSizedIsStillAGuessAfterASave`
  and the two after it). Checked on a throwaway copy the same day: a file
  shaped as 2026.48.1 writes it, a second session out of sight with a
  400pt column, a launch, a quit, a launch and a switch to it. Its column
  came up at 400pt, and at 293 (a third) with the field not read back.
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
  class conforms, `PaneBar`: the tabs, "+" right after the last, and at the
  row's end one stack (`trailing`) of Split Right, Split Down and the button
  that shows while its split is zoomed. A hidden button takes no room there
  (`ZoomedButton`'s width is 0 while hidden, and a stack view lets go of a
  hidden view), so with all three hidden the strip runs to the row's end.
  The two split buttons split *this* split (`splitToTheRight`,
  `splitDownward`: `GitPanelModel.split(region, on:, with: .blank)`), not
  the one with the keyboard, and the split they make holds an empty tab.
  They show only while the row has 240pt of its own, after the clearances
  it gives the window's controls. With all three hidden the stack is empty
  and has no width of its own, which left the strip's end undecided: a
  low-priority width of 0 decides it, and any visible button's own width
  wins over that (`fitSplitButtons`,
  `roomForSplitButtons`, checked when the row's size or either clearance
  changes): in a narrower split the tabs have the row. The "+" (`PaneBar.addTab`)
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
  window once a split could sit to the right of it. The rule that came out
  of the day: a control sits on the thing it acts on. What is about the
  session is the window's, what is about one split is on that split's row.
  The split buttons were in the window's corner until the evening of
  2026-11-26, acting on "the split you're in", and moved to the rows for
  that reason.
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
  after its title and shows no close button, pointer over it or not
  (`applyState` hides it while `isHugging`), and its glyph is never hidden.
  A close button is at a tab's trailing end or nowhere. It is closed by
  coming forward first, by ⌘W, by a middle click, or by Close Tab in its
  menu. For a few hours the button showed over the glyph on hover: two
  places for one button, and a click on the glyph, meant to pick the tab,
  closed it. The probe's `hover-tabs` step reads each tab as it looks under
  the pointer, and a close button on a tab that gave up its room (it would
  lie over the title), one at a tab's start, or a tab without its glyph, is
  a fault. Then the tabs that still can shrink
  together, down to 130pt or their title, whichever is less. Only then does
  the row scroll, with "+" pinned past the visible end. The first step is
  from 2026-11-26: it is what lets Changes and Files both keep their names
  in a 440pt split under the window's buttons (there were six that day). The session's own tab
  never keeps that room at all, since it is never closed (`b7675b2`).
  **The plan has to be a pure function of the row**: the tabs, their titles,
  which is in front, and the width. It was not at first. A tab's
  `fittingWidth`, which the plan starts from, read `isHugging`, which the
  plan sets. So a tab that had been asked to give up its room reported
  itself narrow, the next pass saw a row that fitted and did not ask, the
  tab went wide again, and the pass after asked again. It showed as titles
  cut short ("Ch…", "F") after a tab was added to a row with no room to
  spare, put right by the next layout pass. `fittingWidth` is now the
  natural width whatever the tab is laid out as (`naturalTrailingRoom`),
  and only `trailingRoom`, used for laying the tab out, follows
  `isHugging`. `slideIntoPlace` also sets which tabs give up their room
  before the slide, without animating that, so a tab does not slide to its
  narrow width still laid out for the wide one. Anything new the plan
  reads off a tab view must not be something the plan writes.
- **Bringing the front tab into view measures against the width the row is
  going to** (`SideTabStrip.revealActive(animated:width:)`, called from
  `update` with `plan().visibleWidth`). While a new tab slides in, the
  visible part of the row is still as narrow as it was. Measured against
  that, the new tab in front looked out of view, the row scrolled to it,
  and scrolled back as the row widened: with room for every tab, the tab
  you already had went 58pt out and back each time one was added. Anything
  that asks "is this in view" during a slide has to ask it of the end
  state. `SideTabStrip.motionSample` (Debug) reads the presentation layers,
  and the probe's `trace-blank` and `trace-tab` sample it every 20 ms
  (`../debugging.md`): that is how it was found, and how to check a change
  to the row's motion.
- **How far the row can scroll, and which edge fades, are asked of the
  width the content is going to** (`settledContentWidth`), never of the
  content view. After a close, `slideIntoPlace` leaves the view as wide as
  it was until the tabs have arrived, because a row scrolled past its new
  end would jump the moment the view narrowed. Two places measured against
  that stale width. With room for every tab, closing the last one let the
  row scroll 20pt to "reveal" the tab coming forward, faded both edges, and
  snapped back about 180 ms later (the scroll position read 0, 10, 12, 17,
  19, 20, then 0). A row scrolled to its end did the opposite: it barely
  moved, then jumped 69pt. Adding a tab never showed it, since the content
  grows at once. Three rules for the strip, then, and they are one rule:
  the plan reads nothing it writes, a reveal measures against the visible
  width the row is going to, and a scroll limit against the content width
  it is going to. `trace-close` and `select:<n>` are the probe steps for
  it. The fade follows the same rule since the second review:
  `slideIntoPlace` asks for the fade of the row it is going to
  (`updateFade(width:)`), because nothing else asks before the layout that
  follows the slide. Without it a row that came to fit after a close kept
  its trailing fade for the length of the slide. One case is left as it
  is: during a slide in which the row grows, the fade's mask is already at
  the final width.
- **The empty tab** (`SideTab.blank(id)`, `Wortel/UI/NewTabPage.swift`,
  since 2026-11-26). A tab that is nothing yet, titled "New Tab". A row's
  "+" opens one at the end of its row, in front (`openBlank`), and a row
  that already has one brings it forward instead of making a second. A
  row's split buttons make a split around one. Its page is
  `NewTabPage`, drawn by `TabContent` like any page that is not a
  terminal: five rows, Terminal, Browser, Changes, History, Files, each
  with the key that opens the same thing without asking (⌘T, ⇧⌘B, ⇧⌘C, ⇧⌘H,
  ⇧⌘F: `rows` builds a pane's from the first letter of its title, as
  `MainMenu` has them), Changes with its
  count. A click on a row, or the arrows and Return, calls
  `GitPanelModel.fill(_:with:)`: the split becomes the one you are in, the
  new tab is opened there in front (`NewTabChoice`; a pane that is open in
  another split is moved, as `open(_:in:)` does), then the empty tab is
  closed, then the front tab is focused. In that order on purpose: closing
  first would take a split whose only tab was the empty one out of the
  tree before there was anything to put in it. Escape closes the empty tab
  (`GitPanelModel.dismissBlank`, through `putAway`): the keyboard goes to
  what is in front of that row now, or to the main row when the split went
  with the tab. It was `requestClose` at first, which left the keyboard
  with nothing. ⌥⌘T (Tab ▸ New Tab, `AppDelegate.newTabHere`) is the row's
  "+" as a key: `openBlank` in the split you are in. ⌘T and ⌘D are not
  that, on purpose: they are followed by typing, and here typing picks
  rows. A closed empty tab is not put on the reopen stack
  (`WorkspaceTabs.close`, the `isBlank` guard): every pick closes one, and
  ⇧⌘T was bringing them back. A row's first letter alone picks it too (T, B, C, H, F;
  `Row.letter`, `onKeyPress(characters: .letters)`): not with ⌘, ⌃ or ⌥
  held, and any other letter is ignored. Those are the letters of the same
  things' shortcuts, and the page is the one place where a bare letter
  cannot be meant for anything else. A sixth row has to start with a letter
  of its own. All of the page's keys need it to have the keyboard, and it
  takes it in three cases: when it appears in the split you are in
  (`onAppear`); when the keyboard is sent to a split whose front tab is an
  empty one, by ⌘], ⌃⌥⌘ and an arrow or anything else that ends in
  `GitPanelModel.focusFront(of:)`, which clears the keyboard off the
  terminal and bumps `newTabFocusRequest`; and on a click in the page.
  `settle` also takes the keyboard from a terminal the empty tab covers
  (`onClearKeyboard`), so nothing is typed into a terminal that cannot be
  seen. It is not
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
  view with `sizingOptions = []`. That goes for every page's host, the main
  row's and the strip's too (`MainAreaController.paneHost`,
  `BottomPaneController.paneHost`): a leaf's frame is set by hand, and by
  default a hosting controller turns its page's minimum size into required
  constraints. A page taller than its leaf (the empty tab's, in a strip at
  its minimum or a main row squeezed by ⇧⌘D twice) broke one and drew past
  the leaf. Those two hosts were the last without it.
- **A split of a session that is not on screen costs nothing per change.**
  Every split ever shown in the window has a `SplitPaneController`, and
  each used to sync, and work its page out again, on every tab change of
  the session on screen. Now one that is not in that session is hidden
  once and then left alone (`parked`), and `SplitPanePage` draws nothing
  for it. What it reads while parked is only whether its split is in the
  session on screen, which is what brings it back.
- **Dead splits are let go a turn later** (`letGoOfDeadPanes`), outside the
  tracked read in `syncTree`. Asked inside it, every session's `paneTabs`
  was read there, and any split change of any session in any window synced
  this window again. The trade: a split closed in a session that is not on
  screen in this window is let go at this window's next sync, not at once.
- `setLeaves` asks for a layout only when the leaves' views changed. Every
  sync hands them over, a divider's drag syncs at every step, and each laid
  the whole tree out a second time.
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
  event. A double-click equalizes the whole tree, as ⌃⌘= does. The sizes a
  drag may change are noted on the press (`onDividerPressed`), before
  anything moves: noted at the first step they were already the sizes after
  it, and a drag of one step was never remembered as the column's width or
  the strip's height. A drag holds the divider it was pressed on, by its
  place in the tree and what it stands between
  (`SplitTreeView.Held`, `SplitLayout.sides(of:)`), and is let go of when
  the tree changes under it so that the place names another divider, puts
  it behind a zoom, or is another session's: no more steps, and the
  release neither saves nor remembers a width. Divider views are reused by
  their place in the list, and until 2026-11-27 a split closed during a
  drag (its shell exited, or `wortel split` made one) handed the view under
  the pointer another divider: the drag went on with main|side instead of
  main|split, took the column from 400pt to 801, and
  `setSplitLayout` let it through (the same leaves), so it was saved and
  remembered. Checked 2026-11-27 with `try-splits.sh right column
  hold-close:9 hold-close:1`: with nothing closed the drag goes on; with
  the split closed under it the next step is refused, the column stays at
  its 440pt and nothing is remembered. Not tried with a real pointer.
  To VoiceOver a divider is a splitter
  (`SplitDividerView`: role, orientation, its position as the value), as
  `NSSplitView`'s were while the column was its pane. Increment and
  decrement move it 20pt through the drag's own path (press, drag,
  release), so a move made that way is saved and remembered like any other
  (`../accessibility.md`).
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
  - A slide ends itself when its tree goes. Leaving its window lands it
    (`viewWillMove(toWindow:)`), and a timer whose tree is gone stops and
    lets the resizes go. Before that, a window closed within a slide left a
    timer waking the main thread 120 times a second until quit, and every
    terminal's resize held until the watchdog's two seconds.
  `Motion.pane` is still the sidebar's alone: that one is AppKit's pane.

Making one, and dropping on one:

- ⌘D and ⇧⌘D (`AppDelegate.splitRight`, `splitDown`) put a new terminal in a
  split beside the leaf you're in (`GitPanelModel.currentLeaf`). From Changes
  that is a split beside Changes, from the strip one beside the strip. The
  two buttons at the end of each split's row (`PaneBar.splitRight`,
  `splitDown`) split that row's split, with an empty tab in the new one
  where the keys put a terminal: a key says what it wants, and a button is
  pressed by someone still deciding. (They were two buttons in the
  titlebar's corner, through `AppDelegate.newSplitRight` and `newSplitDown`,
  until the evening of 2026-11-26. Those actions are gone.) Split Right and Split Down in a tab's own menu
  move that tab into a split (`SideTabStrip.onSplit`), and are offered only
  when the tab is not alone in its split, whichever split that is: a
  split's only tab would be split from itself, and `WorkspaceTabs.split`
  refuses it. The session's "…"
  and a row's "+" have no split items. All of them go through the same
  `GitPanelModel.split`, which asks the window
  where the room comes from (`roomToSplit`, `MainAreaController.room`). The
  room is measured in the layout without its zoom, which is the one the
  split is made in, since a split made by a key ends the zoom. Measured on
  screen, a zoomed split was the whole area and always had room, and ⌘D in
  a zoomed side split 300pt wide made two of about 145. A tab dropped on
  the edge of a zoomed split is measured the same way
  (`MainAreaController.hasRoom(toSplit:on:)`): the key and the drag read
  one helper, `unzoomedFrame(of:)`. The first review fixed the key and
  missed the drag. A
  leaf that is two minimums and a gap wide (or high) is halved. One that is
  not takes the new split's room from the whole row or column it is in, an
  equal share from every part (`SplitLayout.insertSpreading`): ⌘D in a side
  column 280pt wide did nothing before that. Only when that row has no room
  either do they beep and do nothing.
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
- **A drag can outlive what it started in, and a drop is refused then.**
  `SideTabView.mouseDown` tracks the drag in a loop of `nextEvent`, which
  runs the main queue while it waits. So a row can go during a drag (a
  split's only tab, its server exited), and so can the session, or the tab
  itself. Three guards, from the review before main. The tab and its row
  are kept alive until the mouse-up (`trackDrag` under
  `withExtendedLifetime`, `SideTabView.strip`): with the row gone the
  drag's end never reached the controller, and the ghost and the lit zone
  stayed drawn over the window. A new drag ends any old one first
  (`TabDragController.finish()` at `.began`, for a tab and for a file).
  And at the mouse-up the drop is made only if the tab is still in a row
  and the session on screen is the one the drag began in (`stillHeld`,
  `sessionOnScreen`, `dragSession`): otherwise a drop on an edge made a
  split in one session holding another session's tab. Not tried by hand:
  each needs a pointer and a tab that goes mid-drag.

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
  (`MainSplitViewController.region(at:)`), so ⌥⌘T, ⌘T, ⌘W and ⇧⌘T act there.
  Two places answer nil, so a press there leaves you where you were: a
  divider, and any of the window's controls (`WindowControls`), which lie
  over the end of whichever row is under them. Without the second, a press
  in the corner would move you to the split under it first.
  When the split you're in closes under you, the keyboard goes to the split
  you were in before it (`GitPanelModel.regionBefore`): what is zoomed if
  something is, else the latest entry of `regionTrail` that still exists
  and is on screen, else the main row. `lastRegion`'s setter keeps the
  trail, the last twelve splits you were in, each once. It covers any split
  that goes with its last tab while you are in it, whatever kind of tab
  that was: a made split, the column when Changes and Files are put away or
  its last tab closes, the strip. Until 2026-11-26 all of those went to the
  main row, so ⌘D three times and then ⌘W put you two splits away from
  where you had just been. Four rules keep it honest.
  - The keyboard moves on a close only when you were in the split the tab
    closed in. A shell that exits by itself in another split leaves it
    where it is. A click on a tab's close button in another split is not
    that case: the click has already put you in that split (a mouse-down in
    a split makes it the one you're in), so the keyboard goes to what comes
    forward there, or back along the trail if the split went.
  - One refocus per close. `close` hands the keyboard on when the split
    stays, for anything that can hold it: a terminal, a browser's page, an
    empty tab's page, a pane's list. (The last two were left out at first,
    and ⌘W on either left the keyboard with nobody, while Escape on the
    same empty tab worked.) `putAway` and `fill` focus the split
    themselves, so they pass `focusesSplit: false`. When two places
    refocused, the first rewrote the trail the second read, and Escape on
    an empty tab put you two splits back.
  - The trail is one session's. `focus(session:)` empties it on a switch and
    stores the row of that session's own terminal. Kept across a switch,
    the next move pushed the other session's split, and closing a split in
    session B could send the keyboard to B's Changes list, a split you had
    never been in there.
  - A split that has gone is nobody's place (`isGone`: a made split with no
    tabs here, the column or the strip out of the tree). `lastRegion` reads
    one as the main row, or as what is zoomed. Only a made split was read
    that way at first, so after the column's only tab was dragged to
    another window ⌘W closed a tab and gave nobody the keyboard. The setter
    compares against what the getter answers, and does not push a stored
    split that has gone onto the trail. Pushed as the main row it would
    bury the split before it: after ⌘D three times, the second ⌘W would go
    to the main row and not to the first ⌘D split.
- A terminal that had the keyboard and goes out of sight in its own row (a
  file, Changes or another terminal picked in front of it) hands it to what
  is now in front of that row, not of the main row
  (`GitPanelModel.handBackKeyboard`, the `handBack` of every row's
  `SideTerminalHostController`). A file takes no keyboard, so nobody has it
  and you are still in that split: ⌘W closes the file. Until 2026-11-27
  every row handed it to the main row, so after a file tab was picked in a
  ⌘D split the session's own terminal had the keyboard, `lastRegion` became
  the main row, and ⌘W closed the session. A row that is out of sight
  hands it to `lastRegion`. And `focusFront(of: .main)` does nothing while
  the main row is behind a zoom, as the other rows' branches already did:
  it gave the hidden row's page or terminal the keys. Checked 2026-11-27
  with `try-splits.sh right file close column tab file close right zoom
  file close` (`file` is a probe step for this): the keyboard with nobody
  after each `file`, the split you were in kept, and each ⌘W closed the
  file. The same run with the old hand-back put the keyboard in the main
  row and ⌘W closed the session.
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
- A session switch shows a covered terminal without giving it the keyboard
  (`TerminalHostViewController.swap`, `SurfaceView.isCovered`): it goes to
  what covers it (`GitPanelModel.focusCover`), the tab in front of the main
  row or of the zoomed split. The main area's check runs a turn after the
  switch lays it out, and a hibernated terminal is swapped in 10 to 500 ms
  later, after it. Until 2026-11-27 nothing ran it again, so back in a
  session whose split was zoomed (or whose main row had a file in front)
  the session's own terminal took the keys, Return included, out of sight.
  Checked with `HIBERNATE_AFTER=0.3 try-splits.sh file next next next
  right zoom next next next`: with the old swap, a file's session came back
  with the keyboard in the terminal under the file, and the zoomed one with
  it in the hidden terminal (a fault); with this one, nobody and the zoomed
  split's terminal.

Known limits:

- A terminal in any split but the main row is a side terminal. Agent
  tracking, naming and resume follow the session's own terminal only.
- A split holds tabs, never another session.
- A side terminal is never hibernated: `HibernationPolicy` is only told
  about a session's own terminal.
- A made split that emptied is hidden at once and leaves the window half a
  second later (`MainAreaController.letGoOfDeadPanes`): a terminal moved out of it
  as its last tab is in its old host until the row it went to has shown it.

A session out of sight and a window resize. Its terminal follows the window
once the resize ends (`SurfaceView.followWindow`), and that used to be "by as
much as the window changed", which was right while the panes beside it kept
their width. With shares, a terminal beside a side column takes only part of
the change. So the app is asked instead (`SurfaceView.sizeWhenShown`, set in
`AppDelegate`): `MainAreaController.terminalSize(of:)` lays the session's own
tree out in this window as it is now (with that session's hidden leaves,
of which there are none since nothing is hidden), and
answers with its main row's page (the leaf less its row, a titlebar row along
the top and 36pt lower down). Behind a zoom on another split it answers with
the size the main row has when the zoom ends, which is the next size it is
shown at. (It answered nothing there at first, and the terminal was resized
again when the zoom ended.) It answers nothing only when the terminal is in
no window of ours. Then, and only then, the old sum is used. A new leaf kind, or a row of another height,
has to be right in `terminalSize` too, or hidden sessions are told a size a
few points off.

`scripts/try-splits.sh` is the test. It runs a throwaway copy of a Debug
build, and `SplitProbe` in it (there only when the copy was started with
`WORTEL_DATA_DIR`, `DataDirectory.wasGiven`)
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
the sidebar collapsed (`sidebar`, and a `swap` step that has since been
removed), and a relaunch: 0 faults.
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
