# The runtime and the surface

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

One `GhosttyRuntime`. A list of sessions, each owning exactly one terminal
surface, each in one main window (`docs/architecture/window-and-sidebar.md`,
Several windows). A surface moving to another window is re-parented into
that window's `TerminalHostViewController`; `SurfaceView.viewDidMoveToWindow`
re-registers what depends on the window.

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
geometry (size/scale → libghostty; light and dark are told by the runtime,
`docs/appearance.md`). One thing about drawing is ours: libghostty's layer
would draw a frame on the main thread at every change of its bounds, and
`frameForNewSize` asks for that frame only for a single change of size, not
at every step of a drag (`../../../docs/decisions.md`, 2026-11-19; measure
with `scripts/bench-resize.sh` before changing it). A terminal's size
otherwise comes from its view when shown, and for one made out of sight its
session's last size on screen (`shownSizes`); one out of sight follows the
window by the window's change (`followWindow`), through the keeper when it has
no surface. The size is the keeper's to apply (`PtyHost.resizeInKeeper`):
libghostty's placeholder grid, reported before the surface is told a size,
never reaches it (`ignoreSizesUntilTold`).

**The surface is a copy of the keeper's terminal** (`docs/architecture/keeper.md`).
It is restored from a snapshot (`KeptTerminalFeed`, waiting for its first size
with `waitForToldGrid` so the copy is not re-wrapped twice on its way), fed the
session's output from the keeper's channel, and answers nothing. Out of sight
for a minute its surface goes (`HibernationPolicy`, `SurfaceView.hibernate`)
and comes back from a fresh snapshot when shown (`wake`); meanwhile the feed
reads what the surface would have raised (`SignalScanner`: titles, the working
directory, bells, progress, a command ending).
`scripts/check-terminals.sh` is the test for all of it. The keyboard path is subtle —
`keyDown`/`performKeyEquivalent`/`doCommand` coordinate via `lastPerformKeyEvent`
and `keyTextAccumulator` to make IME (Korean/Japanese) and unclaimed command
keys work; preserve the upstream comments when touching it. `GhosttyInput.swift`
holds the NSEvent↔ghostty translation helpers and `KeyboardLayout`.
The view is also an **AXTextArea** (`SurfaceView+Accessibility.swift`) so
screen readers and read-aloud apps get the visible screen, the selection and
per-range screen bounds. Every range is UTF-16 into the visible text, mapped to
cells by `TerminalAXText` (pure, tested); Ghostty.app's cell-offset selection
range is the thing not to copy. Built lazily, notifications off until a client
asks. See `docs/accessibility.md`.
