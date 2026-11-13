# The window and the sidebar

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

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
