# The terminal as an accessibility text area

Screen readers and read-aloud apps (VoiceOver, Aiload) read Terminal.app and
iTerm2 through NSAccessibility: the focused element is a text area, its value
is the text, and parameterized attributes say where any range of it sits on
screen. Wortel's terminal does the same. Code: `Wortel/Ghostty/TerminalAXText.swift`
(the mapping, pure, `TerminalAXTextTests`) and
`Wortel/Ghostty/SurfaceView+Accessibility.swift` (the reads and the overrides).

## What a client gets

| Attribute | Answer |
|---|---|
| AXFocusedUIElement (of the app) | the terminal with the keyboard, AppKit's first-responder resolution |
| AXRole | AXTextArea |
| AXValue | the **visible screen**: the viewport, so it follows scrolling back |
| AXNumberOfCharacters, AXVisibleCharacterRange | its UTF-16 length; all of it is visible |
| AXSelectedText | the whole selection, also any part scrolled out of view |
| AXSelectedTextRange | the selection's visible part; {0, 0} when there is none on screen |
| AXStringForRange, AXAttributedStringForRange | substrings (with the terminal's font) |
| AXLineForIndex, AXRangeForLine | a line is a visual row; its range includes its newline |
| AXBoundsForRange | the cells, in screen coordinates; several rows give the rectangle around them, as NSTextView does |
| AXValueChanged | after output, a scroll or a resize, at most 4 a second per terminal |
| AXSelectedTextChanged | 0.1s after a click, drag or key, only when the selection really changed |

**Visible screen only**, by choice: libghostty reads scrollback only as one
block from the very top (a `ghostty_point_s` row is clamped to the screen's row
count, so there is no "the last N lines"), which would mean formatting up to
10 MB of history each time a reader asks after output.

Soft-wrapped rows are joined with no newline, so a word the terminal broke at
the margin is still one word; its bounds are then the rectangle around both
pieces.

## How the ranges map to cells

Ghostty.app does the role, value and selected text the same way but returns
libghostty's selection offsets as the range. Those are **cells** from the
viewport's top left (`y * cols + x`), against a value counted in Swift
characters, and it has no bounds at all. Here every offset is UTF-16 (what an
`NSRange` from a client counts), and `TerminalAXText` maps it to cells:

- **The text** is each viewport row read alone, joined with a newline unless
  the two rows read together have none between them (a soft wrap).
- **A row's cell map** comes from reading its prefixes, columns 0 to c: the
  text grows by a character exactly at each cell that starts one and not at a
  wide character's second cell. So the renderer's own idea of width places
  every character, and there is no width table to disagree with it. An empty
  cell is written only when something follows it, so it arrives as a space
  just ahead of that character, one cell each. Built only for rows a bounds or
  selection question touches.
- **Geometry**: left padding is `tl_px_x` of a read starting at column 0;
  top padding is the IME point's y (the bottom of the cursor's cell) modulo the
  cell height; cells are `ghostty_surface_size`'s pixels over the backing
  scale. Measured from the top, so a resize hold (last frame pinned top left)
  is still right.

The libghostty behaviour this rests on (empty cells held back, spacer cells
silent, a lone spacer reading as its wide character) was checked against the
pinned binary with a throwaway probe. It differs from Ghostty v1.2.3, which
wrote empty cells as spaces at once, so check it again when libghostty-spm
moves; `TerminalAXTextTests` models it in `FakeRow`.

## Cost

Nothing until a client asks. The text is built on the first read after a
change (about 0.5 ms for a full 140×42 screen, 0.1 ms when cached); a row's
cell map costs 0.5 to 1.5 ms the first time. Notifications are off until any
client has asked this process anything; after that, output costs the pty's
queue a lock take and the main thread at most four hops a second per
terminal. The exec backend has no output count, so it hears only of scrolls
(history growing) and caches for a quarter second.

## Verified (2026-11-11)

On an isolated test copy (own bundle id and data folder), with a probe making
the AXUIElement calls Accessibility Inspector and Aiload make:

- AXFocusedUIElement was the terminal, AXTextArea; AXValue matched the screen
  with CJK, an emoji, `e` + U+0301 and a word split by a soft wrap, and
  AXNumberOfCharacters equalled its NSString length.
- AXBoundsForRange for words after CJK, after an emoji, after combining and
  wide characters, after leading spaces, on both halves of a wrapped word,
  after a window resize, after a window move and after scrolling back: the
  window was captured and each rectangle drawn on it, and every one sat
  exactly on its word. (One display only, so a second monitor rests on
  AppKit's `convertToScreen`.)
- A plain drag over a word in zsh: AXSelectedText was the word,
  AXStringForRange of AXSelectedTextRange gave it back, its bounds sat on it,
  and AXSelectedTextChanged was posted; a click clearing it posted again and
  the range went to {0, 0}.
- Output at 20 lines a second gave about 4 AXValueChanged a second, and none
  while idle.

Not tested in a running app: mouse reporting in a full-screen program. The
mouse and key handlers only gained a call that schedules a later look at the
selection, so what they send to libghostty is unchanged.

## The dividers between splits

Not the terminal, but it belongs to the same promise. Since the splits
(2026-11-26) the lines between splits are Wortel's own views
(`SplitDividerView` in `Wortel/UI/SplitTreeView.swift`), where the column's
divider used to be `NSSplitView`'s, which VoiceOver knows. Each is an
accessibility element with the splitter role, labelled "Divider", its
orientation (a line between splits side by side stands upright) and its
position along its axis as the value. Increment and decrement move it 20
points, through the same three calls a pointer's drag makes (press, drag,
release), so a move made with VoiceOver is saved and remembered like one made
by hand. The sidebar's divider is still `NSSplitView`'s.

Not tested with VoiceOver running (2026-11-26): it was written from the API
and read in review.
