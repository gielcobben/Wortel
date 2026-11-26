# Tabs and the workspace

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

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
- **A terminal's host is never inside a SwiftUI view.** All four places a
  terminal can be (the session's own pane, the main area's row, the side
  column, the strip) are AppKit controllers that size the host themselves,
  with SwiftUI's page in a view of its own on top, hidden or taking no
  clicks while a terminal is in front. Inside a representable it is SwiftUI
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
- **Terminals don't resize during pane animations** (`Motion.pane`,
  `SurfaceView.holdResizes`): one resize when it lands instead of one a frame,
  each of which made the program inside redraw. Collapsing panes never resize a
  terminal below 40×20pt for the same reason. A session switch holds them too,
  while the column and strip take the new session's layout
  (`MainSplitViewController.show`).

Width: the column's is per session and the same for every tab, and it may grow
until the terminal has 320pt; the strip's height is app-wide. Tab drags are
resolved by `TabDragController` against the rows and a few drop zones (the
main area, the column, the strip, the far edge for swapping), each only for
tabs allowed there. A file tab can also leave the window: past its edge the
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
