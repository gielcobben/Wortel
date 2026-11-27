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
`false` is never a way to have libghostty do a thing itself: since Ghostty
`f9e8ef02d` its fallback for a clicked link opens nothing on macOS, so OPEN_URL
takes every link (`docs/architecture/files-and-previews.md`).

**The clipboard** (the runtime's clipboard callbacks). libghostty has two
clipboards here: `STANDARD` is the system one, `SELECTION` a pasteboard of
Wortel's own (`<bundle id>.selection`), as Ghostty.app has. A mouse selection
goes to the selection pasteboard (`copy-on-select`, Ghostty's macOS default
`primary` since its 1.4) and a middle click pastes it (`middle-click-action`,
`primary-paste`); ⌘C and ⌘V are the system clipboard. Before 2026.47.4's
Ghostty the runtime said it had no selection clipboard and libghostty fell back
to the system one; on the new Ghostty that fallback is gone, and selecting
copied nowhere and a middle click pasted nothing. The confirm callback tells
two things apart by their request kind: an unsafe-looking paste of yours is
approved without a prompt (multi-line pastes into an agent are the main
gesture), and a program reading the clipboard (OSC 52, kitty's OSC 5522) is
refused with `ghostty_surface_deny_clipboard_request`, which answers it
(`docs/decisions.md`, 2026-11-21).

**A shell that ends** is told to libghostty with how long it ran, up to when
its pty hung up (`SurfaceView.finishProcess`). It was told 0, and an exit
inside `abnormal-command-exit-runtime` (250 ms) reads as a failed launch: a red
banner, and the session kept open after `exit`. A shell that really dies at
once still gets that banner.

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
window (`followWindow`) to the size its main row has in its session's own
splits, which the app works out for it (`SurfaceView.sizeWhenShown`,
`workspace-tabs.md`; by the window's change when nobody can say), through the
keeper when it has no surface. The size is the keeper's to apply (`PtyHost.resizeInKeeper`):
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
holds the NSEvent↔ghostty translation helpers and `KeyboardLayout`, as ported
from Ghostty v1.3.1. Ghostty.app's input fixes since then (to 5ebe501; none to vt-1.0.2) are in
`KeyInputText.swift` (pure, tested) and `keyDown`/`insertText`: text an input
method commits outside a key (Dictation, the emoji picker) goes through the key
encoder, never `ghostty_surface_text`, which is a paste and showed up in an
agent as one; a key that commits a composition sends the text alone, and is
replayed only for an arrow; a control key while composing is the input
method's; no key text starts with DEL; and `doCommand` performs nothing, so
⌘↑/⌘↓ are libghostty's previous and next prompt (verified by build and unit
tests 2026-11-23, not yet by hand).
The view is also an **AXTextArea** (`SurfaceView+Accessibility.swift`) so
screen readers and read-aloud apps get the visible screen, the selection and
per-range screen bounds. Every range is UTF-16 into the visible text, mapped to
cells by `TerminalAXText` (pure, tested); Ghostty.app's cell-offset selection
range is the thing not to copy. Built lazily, notifications off until a client
asks. See `docs/accessibility.md`.
