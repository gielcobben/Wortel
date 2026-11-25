# The window and the sidebar

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**UI shell** (`Wortel/UI/`) — three AppKit split panes (`MainSplitViewController`)
hosting SwiftUI content, in an AppKit window (`AppDelegate`). The titlebar is
Wortel's own (`TitleBars.swift`): the window keeps an *empty* toolbar only for
its height and the centred traffic lights, the titlebar is transparent, and each
pane draws its row of a flat grey band (the ChatGPT app's look). The sidebar
toggle and Back/Forward are the exception: one set laid over all the rows
(`SidebarControls`, in `BackdropController`), placed on every layout pass and
split resize (the first real layout at launch sends no resize) so
the arrows ride the sidebar's edge as it opens and closes and the rows to the
right clear them (`leadingClearance`). The reason for the own titlebar is
that on macOS 26+ every toolbar item, custom views included, sits on a Liquid
Glass capsule, and AppKit has no switch to stop that. The window's vibrancy is
one behind-window material under everything (`BackdropController`); only the
pages (terminal, column) are opaque. While the list runs past the window its
bottom edge fades (`SidebarScrollView`, a layer mask), and the mask takes
vibrancy away from everything in the list: a grey there is an NSColor label
colour, never SwiftUI's `.secondary`/`.tertiary`, or it draws dark on dark
(the headers did, 2026-11-19). Sidebar selection is a custom neutral
pill rather than `List(selection:)` because the sidebar never holds keyboard
focus (the terminal does). That is enforced, not assumed: `SidebarOutline`
refuses first responder. A table takes the keyboard on any press its own code
handles, and until 2026-11-19 only a press that switched sessions kept it
with the terminal (the switch handed it there first); the session already on
screen, a folder's header, ⌘- and ⇧-click all left it in the list, which draws
no focus, so typing went nowhere until the terminal was clicked. Pressing the
session already on screen gives its terminal the keyboard
(`SessionManager.returnKeyboardToSession`, or what is in front of the main
area if a tab covers it), and so does ending a rename with Return or Esc, or
by a press elsewhere in the list. `TerminalHostViewController` is the key trick: it keeps **every**
session's `SurfaceView` in the hierarchy and switches via
`isHidden`/occlusion/first-responder — never `removeFromSuperview`, never a
rebuild — so switching back is instant with no flash. Its pane is AppKit
(`TerminalPaneController`): the host fills it by its autoresizing mask, and
the pages that can stand in for a terminal are a SwiftUI view on top that
takes no clicks unless one is up. The pane calls `show()` again whenever the
selected session, its being prepared or there being no sessions changes, so
`show()` early-returns when already showing the surface (otherwise it would
steal focus from the rename field). A session switch doesn't wait for that,
though: `SessionManager.onSwitch` runs
`MainSplitViewController.show` in the same turn as the selection, which lays
out the session's column and strip first and only then shows its terminal,
with resizes held throughout, so the terminal is shown at its final size and
the one being left is never resized. Waking a dropped terminal holds resizes
until it is restored and swapped in, for the same reason.

**Several windows** (`MainWindowController`, `SessionWindow`, `WindowStore`,
since 2026-11-19). Each main window is a `MainWindowController`: its NSWindow,
split, titlebar rows, git panel and file tree, all one per window, wired to
the app by `AppDelegate.wire`. Its share of the session list is a
`SessionWindow`: the session in front there, its ⌘1…⌘9, its drawn row order,
its attention flash and whether it is on screen. The views of a window read
*its* `SessionWindow` (`home`), never `manager.selected`, or the window behind
would draw the session you are in.

- **The active window** (`SessionManager.activeWindow`) is the main window last
  made key. `manager.selectedID` is its selection, so the menu commands, ⌘P's
  current row and a new session's folder keep meaning "where you are".
  Assigning `selectedID` a session in another window selects it there, makes
  that window active and brings it forward (`onActivateWindow`): that is how a
  notification, ⌘P and Next Waiting Session reach another window. The
  delegate's `window`, `gitPanel`, `fileTree` and `splitController` are the
  active window's.
- **Moving** is `SessionManager.moveSessions(_:toWindow:)`: the window left
  shows its next row first, then the session's `windowID` changes and the
  new window shows it. The terminal is re-parented by that window's
  `TerminalHostViewController`, which never hides a view another host has
  taken (`ownCurrentView`); nothing is restarted. A window left empty closes
  (`onWindowEmptied`). Sidebar drops from another window move first and are
  then placed as any drop; a drag that ends outside every Wortel window makes
  a new window there (`draggingSession(_:endedAt:operation:)`, operation none).
  An Esc-cancelled drag ends the same way, which is left as it is, as Safari's
  tab drag is.
- **Closing** a window that isn't the last closes its sessions through
  `requestClose` (the usual question if something runs, worktree sessions
  archived); it goes when the last has. The last window closes as the one
  window always did: the app quits and the sessions live on in the keeper.
- **Saved** in `windows.json` beside `sessions.json`, in the order opened:
  each window's id, frame and front session. Each session carries its
  `windowID`. An older build drops that field, so the next launch puts
  everything in the first window and drops the windows left empty
  (`WindowStore.assign`, tested). The sidebar's width is still the split's one
  autosave, shared by all windows. The first window is placed before restore,
  so no terminal is laid out at a size it is about to leave.
- **Spring-loading** (`SpringLoading`): a drag held still over a main
  window that another main window is in front of brings it forward, as the
  Finder's windows do, after the Mac's own spring-loading delay and only
  while its setting is on (`com.apple.springing.enabled` and `.delay`, the
  Accessibility ▸ Pointer Control switch). Every drag that can end in
  another window reports the pointer: session rows (`SidebarOutline`), tabs
  (`TabDragController`), files out of a list (`AppDelegate.fileDrag`) and a
  preview window dragged by its row (`previewWindows.onDock`). It looks at
  the window a click would land in (`NSWindow.windowNumber(at:)`), so a
  window covered there by another app, or by a preview window, stays where
  it is, and it does nothing once the button is up.
- **A declared, empty folder** is drawn in the first window only
  (`sidebarGroups(in:)`); a folder with sessions is drawn in each window that
  has some.
- Still one of each, app-wide: the ⌘P panel (shown over the active window),
  the preview windows, Settings, and the anchors of the sidebar's popovers
  (update, permissions, telemetry), which are the sidebar made last.
- **The permissions icon is also where setup is** (`Permissions`,
  `PermissionsPopover`). It is in the bar only while something is off:
  notifications never asked or refused, no git (`DeveloperTools`), or no
  agent found and the popover not yet opened once. The popover's Setup
  section holds "An agent" and "Git", each only while missing, above the
  two permissions. An agent is looked for at launch (after the first frame)
  and when the popover opens, until one was found or reported once
  (`setup.agentSeen` in the defaults), and never after. "None" is said only
  when the login shell itself answered none; no answer shows nothing.
  Picking one from the row's menu types its installer on a prompt, unsent
  (`SessionManager.offerCommand`): the session in front when its terminal is
  the tab in front and its shell is at a prompt, else a new plain session
  with the line typed ahead.

**Sidebar selection and order** (`SidebarOutlineView`, `SessionSelection`,
`SidebarSort`, both pure and in `WortelTests`). A plain press on a session
switches to it on mouse-down, as Finder's sidebar does (`SidebarOutline.mouseDown`
→ `sessionPressed`); the table's action only fires on mouse-up, after AppKit
has ruled out a drag. A press on a row inside a selection of several waits for
mouse-up, so the selection can still be dragged. ⌘-click and ⇧-click select
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
`SidebarStep`). Closing the selected session goes back to the one you were in
before it (`SessionWindow.trail`: visits of 3 seconds or more, or that you
typed in, and the session ⌘N was pressed in), else the row below, else the
row above. The selected row sorts by the key it had when it was last drawn until selection leaves it
(it was read the moment you selected it), and nothing re-sorts while the
pointer is on a row or a button is down; rows slide with `moveItem`, not a
reload. A drop is placed *before the row drawn below it* (`moveSessions(before:)`),
which means the same thing in the stored order as on screen, so dragging while
sorted still writes the manual order.

**Sections and how each sorts** (`SidebarLayout`, `SidebarRoot`,
`SectionSort`, all pure and in `WortelTests`). The sections run Pinned, the
folders, then Sessions (the folderless ones, under their own header), as a
list of chats sits under its projects. In the outline Sessions' rows are root
rows after its header, not its children, and every root index (a row, a drop,
the insertion line, a fold's slide) goes through `SidebarRoot`. Each section
but Pinned has a **Sort By** in its "…" (`SectionSortMenu`): Recent,
the default, Created, Name, or Manual. It is stored per folder name, ""
for Sessions, only when it isn't the default (`SessionManager.sectionSorts`,
UserDefaults, carried over a folder rename). Recent is
`Session.lastSentAt`, set by `SurfaceView.onSubmit` on a Return of the user's
own, else `createdAt`; both are saved with the session. Like Sort Unread
First, a section's sort is a view over the stored order: `SidebarPane` hands
the outline each group's `sortedIDs` beside its stored ids, the coordinator
draws them with `SidebarSort.draw(manual:base:…)` (the unread band over the
base), and a change to the base waits while a click may be on its way, while
a change to the stored order (a drag in a Manual section) is drawn at once.
A drop into a section that sorts itself goes onto it: the folder's or the
Sessions header lights up, no insertion line is drawn, and a drag that stays
inside its own sorted section is refused.
