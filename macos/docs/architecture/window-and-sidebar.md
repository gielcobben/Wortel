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
pages (terminal, column) are opaque. Sidebar selection is a custom neutral
pill rather than `List(selection:)` because the sidebar never holds keyboard
focus (the terminal does). `TerminalHostViewController` is the key trick: it keeps **every**
session's `SurfaceView` in the hierarchy and switches via
`isHidden`/occlusion/first-responder — never `removeFromSuperview`, never a
rebuild — so switching back is instant with no flash. `updateNSViewController`
fires on any observable change, so `show()` early-returns when already showing
the surface (otherwise it would steal focus from the rename field). A session
switch doesn't wait for SwiftUI, though: `SessionManager.onSwitch` runs
`MainSplitViewController.show` in the same turn as the selection, which lays
out the session's column and strip first and only then shows its terminal,
with resizes held throughout, so the terminal is shown at its final size and
the one being left is never resized. Waking a hibernated terminal holds
resizes until it is swapped in, for the same reason.

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
`SidebarStep`). The selected row sorts by the key it had when it was last drawn until selection leaves it
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
