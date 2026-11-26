# Mark-up

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**Mark-up** (`Wortel/Markup/`) is pointing at what a preview shows and saying
something about it, for an agent to read. A button in the preview's header
(or View ▸ Mark Up, ⇧⌘M) turns it on. A click picks an element of a page, a
drag draws around anything, each mark gets a colour, a number and a picture
of its area, and a note bar at the bottom of the preview holds one sentence
with the marks in it as chips. Return copies plain text: the sentence, the
paths of the pictures, and the path of a details file. Nothing is typed into
a terminal and nothing is sent.

It works over every preview Wortel can see into: a page in a browser tab,
a file's source, its diff, rendered Markdown, an image. In a file tab, a
preview window and a browser tab's Page · Source alike. In a page a click
picks an element; in a file a mark is a drawn area (picking a line or a
block, and the lines' own text in what is copied, is the plan's next
phase). The decisions and what was weighed are in
`../../docs/decisions.md` (2026-11-25, under Files, previews, browser).

## One layer, an adapter per kind of preview

The marks are drawn by one native view, `MarkupOverlayView`, laid over
whatever is previewed. It is a sibling of the preview, never a part of it:
a page can neither break the marks nor be changed by them, and a picture of
the preview has no mark in it unless one is drawn there on purpose.

What differs per kind of preview is how a mark stays on its content and how
a picture is taken. That is `MarkupSurface`, one adapter per kind. The layer
never asks what it is over.

| Kind | Drawn and scrolled by | Adapter |
| --- | --- | --- |
| A page | `WKWebView`; WebKit scrolls it in another process | `WebMarkupSurface`: an element, as the page's script reports it |
| Source, Diff | `DiffView`: an `NSScrollView` over an `NSTableView`, fixed row height | `LinesMarkupSurface`: a row |
| Rendered Markdown | A SwiftUI `ScrollView` over a `LazyVStack` | `BlocksMarkupSurface`: a block |
| An image, an SVG | `NSImageView`, scaled down to fit, no scrolling | `ImageMarkupSurface`: the picture |
| A PDF, a font, an archive | `QLPreviewView`, closed to us | None. No button there |

A mark (`Mark`) is tied to something of the preview's, and its shape is kept
in that thing's own units from its origin: `.thing` is the whole of a picked
element, `.area(box:ink:)` a drawn area and its ink. `MarkPlacement` says
where that thing is now (origin, size, the points per unit, and the part of
the view it may show in), and the layer and the pictures both draw from it.
So a mark moves and zooms with its content with no arithmetic of its own.

**Everything an adapter registers is added in `activate` and removed in
`deactivate`.** That rule is what makes "off costs nothing" checkable.

**Everything the layer calls on an adapter is a requirement of the
protocol**, never only a default in its extension. A member that is only
in the extension is the adapter's own when the adapter is held by its
type, and the extension's when it is held as `any MarkupSurface`, which is
how the layer holds it. `attach(to:)` was such a member: the file
adapters' tests called them by their type and passed, and in the app no
mark on a file was tied to anything (found by the owner's hand,
2026-11-25, and then reproduced with the layer mounted the way
`PreviewContent` mounts it). The tests hold every adapter by its protocol
now.

## A page

`WebMarkupScript` runs in a content world of Wortel's own
(`WebMarkupSurface.world`). It only reads: no element is added to the page,
no attribute set. It says what is under a point (through same-site frames
and open shadow roots; a frame from another site is one thing), remembers
the element a mark is tied to, and posts where those elements are whenever
that may have changed: a scroll anywhere in the page (one capturing
listener a document), a resize, the page changing itself (a
`MutationObserver`, at most once a frame). It listens only between `start`
and `stop` and posts nothing while there are no marks. A report is a flat
list of numbers, read by `WebMarkReport` as if it could be anything.

**What a page says about itself is not trusted.** An element's name, id,
selector and text are whatever the page's author wrote, and what is copied
is pasted into a terminal. Every string from the page is cut to a length
and passed through `MarkText.clean` on its way in (`WebMarkupSurface.text`):
control characters, line and paragraph separators and invisible formatting
characters are removed, so a name cannot carry an escape sequence, end a
bracketed paste or start a line of its own. The words themselves are the
page's, quoted and short; an agent reading them reads a page.

An element is followed by reference, so a fixed header's mark stays with
the header, and a mark inside a scrolling panel moves with the panel and is
cut off where the panel is (the report carries the clip). An element that
left the page is looked for again by its selector, since a page that draws
itself anew replaces its elements with like ones. One that is not found has
no place: its mark is not drawn, and its chip and its picture stay.

Measured 2026-11-25 (macOS 27.0.1, 120 Hz, a throwaway harness with a clear
window, scroll events handed to the web view):

- **A report reaches the app a median 0.6 ms after its scroll event** on an
  idle page (5.4 ms at most), and 14.6 ms (41 ms at most) on a page whose
  main thread was busy 40 of every 50 ms. So a mark lands in the same frame
  or the next, and trails for as long as the page stalls. Marks that are
  owed a report for longer than 50 ms are drawn faint until it comes
  (`MarkupOverlayView.scrollWheel`); a scroll at the page's end owes
  nothing (`WebMarkReport.wouldScroll`).
- **`takeSnapshot`'s rect is in the view's points from the top-left**,
  exact at 2x and under page zoom (an element at CSS 100, 200 is at 150,
  300 at zoom 1.5), and the web view is flipped. Past the view's edge a
  snapshot is white, so a mark's picture is the part of it that was
  showing.
- **`createPDF` holds the whole page without scrolling it**: a 6,000pt page
  in 8 ms, one page, the part below the fold included, a fixed header once
  at the top. That is the picture of the whole. Stitching scrolled tiles,
  as cmux does, was not needed.
- **The world is separate**: a global set in it is `undefined` to the page,
  and so is its message handler. It reaches a same-site frame's document.

Checked the same day with the app's own layer, session, adapter and script
over a fixture page, driven by events handed to the layer: a click picked
the button (`button "Download for macOS"`, `#buy`, its styles), a drag drew
an area with the paragraph inside it, picks worked inside a scrolling panel,
on a fixed header and inside a frame; the marks followed a page scroll, the
panel's own scroll and page zoom; a replaced element was found again and a
removed one lost its place; the five pictures, the whole and the details
file were written; and the page's markup was unchanged. Not checked there:
how it feels under a hand (see "Not verified").

The layer is mounted in AppKit, in `WebViewContainer`, as a sibling above
the web view whose frame it follows. Not as a SwiftUI overlay on the tab:
the Web Inspector docks into that container and resizes the web view, and
the layer must cover the page and never the inspector.

While mark-up is on over a page (`BrowserPage.markupChanged`):

- The swipe back is off. Scrolling passes through the layer to the page,
  and a sideways scroll must not become a step back in history.
- The web view ignores the pointer moving (`BrowserWebView.isMarkingUp`). A
  view on top takes the clicks, but a web view hears the pointer through a
  tracking area, and would go on lighting what it passes and setting its
  own cursor.
- A reload owed for a changed file waits (`fileChanged`, `reloadWhenShown`)
  until mark-up is off. A reload drops the note, and this one would do it
  mid-sentence for an edit nobody at the page asked for.
- ⌘+ and ⌘R still reach the page with the keyboard in the note
  (`BrowserTabs.page(holding:)` counts the note as its page's).

## A file

One mount covers a file tab, a preview window and a page's source:
`PreviewContent` lays `MarkupOverlayHost` over its content, under the find
bar, while its session is on (and not over a tab kept built behind the one
in front). SwiftUI places the layer here, over views SwiftUI also places, so
a file's adapters convert through the layer (`attach(to:)`) and assume no
shared origin.

A file tab's views are rebuilt whenever the tab comes back from behind
others, and its marks must not be. So the adapter lives with the session,
and the views sign in to `MarkupViews` as they are made: `DiffView` its
table, `MarkdownView` the view that stands for its stack, `ImagePreview`
its image view. Weak, all of it.

- **Source and Diff** (`LinesMarkupSurface`). A mark is tied to a row, and
  the row's height is its unit, so ⌘+ scales it with the text. The clip
  view's bounds notification moves the marks in the frame the rows move.
  A file is rewritten under its preview all day, so a mark remembers what
  its row held (`DiffView.Coordinator.key(ofRow:)`: the text and which side
  of a diff, not the number) and after a change looks for that row within
  400 either way. A line that is gone has no place; its chip and picture
  stay. The whole file is pictured by scrolling the table a screen at a
  time and putting the scroll back, all in one turn of the run loop, so
  nothing on screen moves (`ViewPicture.tiles`). As wide as the view, so
  one very long line does not shrink the rest.
- **An image** (`ImageMarkupSurface`). Every mark is in the picture's own
  points; only a resize moves it. A mark's picture is cut from the file's
  own pixels, not from the screen: a screenshot shown at half its size
  gives four times what the screen has. An SVG is drawn at twice its
  size.
- **Rendered Markdown** (`BlocksMarkupSurface`). A mark is tied to a block,
  as an offset from the block's corner. Not to a place in the document: the
  stack is lazy, blocks above the view have guessed heights, and every
  guess corrected moves what is below it (`MainArea` records the same for a
  reader's place). `MarkdownView` reports each built block's frame in the
  stack through a second preference, empty unless mark-up is on. A frame in
  the stack does not change when the document scrolls, so scrolling costs
  no SwiftUI update. A block that is not built has no frame and its mark is
  not drawn, which is right: it is out of view.
- **The picture of the whole, for Markdown, is what is in view**, and the
  copied text calls it a part. Measured 2026-11-25: scrolled 4,000pt down,
  the stack had drawn nothing by the end of that turn of the run loop and
  had drawn it a moment later. So a document could only be pictured whole
  by being seen to scroll from end to end. Each mark has its own picture
  either way.

A mark's picture is 4,096 pixels a side at most (`ViewPicture.mostPixels`),
and a picture with no pixels of its own is never drawn larger than that. An
image's size is what its file declares: an SVG that says it is 100,000
points wide must not be drawn into a bitmap of 200,000.

Pictures of the app's own views are `cacheDisplay` on the clip view, which
has no scroller in it, laid on the page's colour: a file's views draw no
background of their own, and a picture of one alone would be dark text on
nothing.

Checked 2026-11-25 in `MarkupFileTests`, against the real table and image
view in a window that is never shown: a mark follows its row through a
scroll, finds its line after three lines are added above it, loses its
place when the line is deleted and has it back when it returns, and grows
with the text; a picture of an area has the rows in it; a 200-line file is
pictured whole with a tinted row where it is in the file, and the scroll
is back where it was; an image's mark is in the picture's points and its
picture in its pixels. And against the real `MarkdownView` in a clear
window: frames for the 9 built blocks of 129, a mark tied to its block,
moved by a scroll in the same call, a picture with the text in it.

## When it ends

There is no lock on the header. When what was marked up goes elsewhere,
mark-up ends and the marks and the note are dropped (`MarkupSession.end`):
a new address or a route change (`webView.url`), a load committed
(`didCommit`, which a reload is), Page · Source, the page's process dying,
the tab closing; and for a file, another of Diff · Source · Rendered
(`PreviewContent`, and `MarkupSession.prepare`), its tab or window
closing. A file rewritten on disk is not elsewhere: the marks stay, each
where its line or block now is. One rule covers what the person does and what a page does
by itself, which nothing could lock anyway.

Esc and a copy only turn it off (`turnOff`): the note is kept, and turning
mark-up on again finds it. ⌘A then ⌫ in the note clears it.

## The note

`MarkupSession` is one per preview, beside its find. It holds no view: the
layer comes and goes with the tab, the session stays.

**The note's text says which marks exist.** A mark is a chip in the text
(`MarkChipAttachment`), so deleting the chip removes the mark and undoing
that brings both back (`textStorage(_:didProcessEditing:…)`), with nothing
kept in step by hand. A number is never reused while a note lives.

**What the bar is made of.** One card (`MarkupNoteBar.card`): the
`.popover` material, over it a ground of the page's raised colour at 86%,
one hairline for an edge and a shadow under it. The card's layer is what
cuts all of it to the bar's shape (16pt continuous corners) and carries the
edge as its border, so the material, the ground and the line end on the
same pixel. The edge is one pixel of the screen it is on (`1 /
backingScaleFactor`), black or white at 16%. The shadow is set through the
view's `shadow`: AppKit owns a view's layer and puts a shadow set on the
layer back to none, which is why the first bar had no shadow at all. Copy
is the system's default button. The bar floats 16pt from the preview's
edges (12 in a column under 420pt), 640pt wide at most.

It was the system's glass (`NSGlassEffectView`) for a day, and is not any
more (`docs/decisions.md`, 2026-11-25): glass let a page's text through as
a smear behind the note's own, and its rim is soft by design where the
owner wanted an edge.

**The words are read against the ground, not against the material.** A
material alone lets a page's text through: seen by the owner over a README,
and again in a capture with a paragraph under the bar. At 86% a little of
the page still shows, which is what says the bar floats.

**The pointer over the bar is the arrow** (a cursor rect over the whole
bar; the text keeps its I-beam). The preview around it has the crosshair,
and a button has no pointer of its own to put back.

**Over rendered Markdown the bar lines up with the reading column**: the
column and the bar's own 16pt padding more either side, so the note's
words start under the document's and the bar stands a little proud of the
text (`MarkupSurface.readingColumn`, which only the Markdown adapter
answers, from any built block's frame; `MarkupOverlayView.barSpan`). In a
window too narrow for that it is centred. Elsewhere it is centred, 640pt
at most. The column is asked for on every report from the adapter and
compared with where the bar is. The first version compared it with the
column the bar was last laid out to, which was the stale one, so the bar
took its place only at the first scroll. Measured in the real Markdown
mount at 380, 640, 900 and 1,300pt on 2026-11-25: in place from the first
look, and unmoved by a scroll.

**The caret of a note come back to is at its end.** A layer made anew has
a text view made anew, whose caret is at the start, and a new mark's chip
goes where the caret is: after Esc and back, or a tab come back from
behind another, every new mark landed before the sentence (found by a run
over a page, an image and Markdown, 2026-11-25).

**A chip can be clicked.** It is selected as one character is (⌫ removes
it, typing replaces it), and its mark is brought into view if it is not
(`MarkupSurface.reveal`): a page eases its element to the middle, a table
puts the row a third of the way down, and Markdown asks the document's own
scroll reader for the block, which is the only thing that can scroll to a
block not yet built (`MarkupViews.revealBlock`). A new mark's chip goes in
after what is selected, never in place of it: a drawing is not typing, and
with a chip selected it would otherwise delete the mark that chip stood
for (found by the first trial of the click, 2026-11-25).

A chip has 3pt of clear room either side, as part of itself, so two chips
or a chip and a word do not touch. The text is lifted to the middle of its
line: a line is 22pt to hold a chip, the caret is as tall as the line, and
with the text at the line's foot the caret stood well above it.
`NoteTextView` also draws the caret itself at the text's height, which a
text view honours when a subclass draws it; whether macOS 27's own caret
view does was not seen, since a caret shows only in a key window.

A trash button clears the whole note while there is one and the row has
room for it; it is an edit of the text like any other, so ⌘Z brings it all
back. A press on the bar beside the text puts the keyboard in the note.

To look at the bar as it is really drawn, an off-screen `cacheDisplay`
render is not enough: it shows no material and no shadow. A window kept
off the edge of every screen, read back with `CGWindowListCreateImage` for
that one window (through `dlsym`: the SDK marks the call unavailable, and
for a window of one's own it needs no Screen Recording permission), shows
both. That is how the missing shadow was found (2026-11-25).

The bar is `MarkupNoteBar`: an `NSTextView` on an explicit TextKit 1 stack
over the session's `NSTextStorage`, so undo, spelling, dictation and input
methods are the system's. It has its own `UndoManager`, for the reason
`CommitMessageEditor` gives, and takes ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z itself, since
those are the terminal's in `wortel.conf` and not on the menu. Return
copies, ⇧Return and ⌥Return make a line, Esc goes back one step (see
"The tools"). Pasting is plain text only, and Writing Tools are off: both
would put a chip in the text with no mark behind it, or take one out.

## The tools

Five, in a row along the bottom of the note bar with Copy at its other end
(`MarkupTool`, `MarkupNoteBar`): a box, the pen, an arrow, a highlighter,
and after a divider the one that moves a drawing. The box is first and is
what is in hand to begin with: most marks say "this area", and a box says
it exactly where a hand's loop is rough. They are the chrome's own
glyph buttons (`HoverFillButton`: 28pt, 8pt corners, a 14pt glyph), the one
in hand lit. The tool is the session's, so it is still in hand when a tab
comes back.

- **A pen is how an area is drawn**, and the mark remembers which
  (`Mark.pen`, `MarkPen`). The pen and the highlighter keep the hand's own
  line, a box its two corners, an arrow its two ends
  (`MarkStroke.points(for:drawn:straight:)`), and `MarkStroke.path(for:through:)`
  makes the line of them, for the layer on screen and for every picture
  alike. A highlighter is 14pt wide at 35%, its ends cut square. A box is
  a 2pt dashed line (6 on, 4 off, `MarkPen.dash`), on screen and in every
  picture: a picked element is outlined solid, and a drawn box in a solid
  line was the same rectangle, with nothing to say which of the two is
  tied to an element.
- **Shift straightens** whichever is in hand: a line in steps of 45 degrees
  with the pen, the highlighter and the arrow, a square with the box.
- **A mark is called by what it was drawn with**: "area 2", "box 3",
  "arrow 4", "highlight 5", on its chip and in what is copied, and
  `details.json` has it as `shape`.
- **A click still picks an element** of a page with any pen in hand. Only a
  drag draws.
- **Move** takes a drawn mark by anywhere in its box and carries it. Let
  go, it is tied again to what is under it there (the same call that tied
  it first) and pictured again; it keeps its number and its chip. A picked
  element is not moved: it is where its element is. With Move in hand the
  pointer is the arrow, and a hand over a drawing.
- **Move also selects and resizes.** A press on a drawn mark selects it,
  and nothing about it changes until the press has travelled 4pt, so a
  click never nudges it. A box, a pen line or a highlight shows a 1pt
  accent outline round its ink and four 9pt handles (white, a 1pt accent
  edge, taken from 20pt around); under 16pt a side only the bottom-right
  one, since four would crowd it. An arrow shows a handle on each end and
  no outline. A corner scales the points about the opposite corner: Shift
  keeps the proportions, Option scales about the middle, and past the
  opposite corner it mirrors. Never under 8pt on its longer side, and a
  line stays as wide as it was. An arrow's end moves alone, in steps of 45
  degrees with Shift. Let go, it is tied and pictured again as a move is.
  The geometry is `MarkStroke.handles`, `handle(at:)` and `resized`, pure
  and tested; the layer only hands the mouse to them. The selection is
  layers of the overlay, placed again whenever the marks are, and is in
  no picture.
- **Esc goes one step at a time**: what is in hand (a drawing being
  carried, a handle, a stroke) is put back, then the selection is
  dropped, then mark-up is left (`MarkupOverlayView.cancelStroke`).
- **The pointer on a chip shows its mark**: every other mark stands back
  to a quarter while it rests there (`pointOut`).

Checked 2026-11-25 with the layer mounted the way a file tab mounts it,
events handed to it as the mouse would: a box, an arrow drawn level with
Shift held, a highlighter stroke, the box moved 60 by 40 and pictured where
it landed, and a drag with Move in hand on nothing drawing nothing. And for
selecting and resizing: a click selected the box and did not move it; its
bottom-right handle dragged by (40, 30) grew it by that; Shift kept its
proportions and Option scaled it about its middle; Esc with a handle in
hand put it back, the next Esc dropped the selection, the one after left
mark-up; an arrow's tip moved and its tail did not; the handles moved with
a 34pt scroll.

Not built, from what tldraw does (its select tool's source, read the same
day): rotation, handles on the sides, arrow keys to nudge (the keyboard is
in the note), dragging a copy out with Option, snapping guides, a bend in
an arrow. Known gaps: Shift or Option pressed mid-drag takes effect at the
next movement, since the layer is not the first responder and hears no
change of modifiers; before macOS 15 there is no public diagonal resize
pointer and a handle shows the crosshair.

## What is copied, and where it goes

`MarkupNote.copied` makes the text:

```
Make button "Download for macOS" (/…/Markup/2026-11-25/3/1.png) the same blue as area 2 (/…/2.png)

Page: http://localhost:4321/pricing
All marks: /…/whole.png
Details: /…/details.json
```

- A mark's picture is taken when the mark is made and written at once, so
  a note holds paths and no bitmaps. A picked element's is the element with
  8pt of room, clean. A drawn area's has its ink on it and what is around
  it: 32pt more a side, and never less than 360 by 160 (`MarkStroke.pictured`),
  so the picture can be placed without another.
- `whole.png` is the whole page with every mark and badge drawn on it
  natively (`MarkupPicture.whole`), 1,600 pixels wide at most. Past 12
  screens tall it is the stretch from a screen above the first mark to a
  screen below the last, and the line says "The part with the marks". For
  rendered Markdown it says "What was in view". Whichever it is, a mark
  that is not in the picture is named: "What was in view (area 1 is not in
  it)".
- `details.json` (`MarkupDetailsFile`) has, per mark, its number, colour,
  name, picture and place, and for a page's element its tag, text,
  selector, key styles and HTML; for an area, what lies inside it.
- A second copy of the same note writes `whole-2.png` and `details-2.json`.

`MarkupStore` puts them in `~/Library/Caches/<bundle id>/Markup/<day>/<n>/`:
no space in the path, no folder macOS asks permission for, and none it
empties by itself. A test copy has a bundle id of its own, so a folder of
its own. A note's folder is removed seven days after its last write, at
launch (with the pasted images) and whenever a new note's folder is made;
the folders of notes still open are skipped. Removed, not moved to the
Trash.

Both of those last two come from the first note an agent read, the
owner's, pasted into the session that built this (2026-11-25). The agent
opened all four files unasked and found both places in the file. What it
could not do: find the first mark in the picture of the whole, which the
line called "the part with the marks" and which showed only the second;
and place the second mark from its own picture, which was a loop at a
paragraph's edge and showed half of two words.

## What it costs

Off: a `MarkupSession` per page whose header has been drawn (a flag and
empty lists), one button, one flag check in the web view's pointer methods.
No layer, no script in any page, no message handler, no observer, no timer.

On, with its tab behind another, its column closed or its session not the
one showing: the layer has left its window and let go of everything, the
page's listeners included. What stays is the note's text and the names of
its pictures. Off, with a note kept, the page's script holds which elements
the marks are on and nothing runs.

There is no repeating timer anywhere in it.

## Not verified

- How the marks follow a page under a hand: a trackpad, a wheel mouse,
  momentum, the bounce at a page's end. The numbers above are from events
  handed to a web view in a clear window.
- The crosshair over a page that sets cursors of its own, and that the
  page stops lighting what the pointer passes.
- Return while an input method is composing (Japanese, Pinyin).
- The note bar's default button's accent, its caret and the pointer over
  it: each needs a key window or a real pointer. The bar and the marks were
  captured as really drawn on macOS 27 over a paragraph, light and dark, at
  260, 384 and 640pt, and its corner looked at enlarged; such a capture is
  of an inactive window.
- That Claude Code and Codex each read a picture from the cache folder
  without asking.

## Known limits

- A frame from another site is picked as one thing.
- The note takes the keyboard, so the page sees a blur: a menu that closes
  when the page loses focus cannot be marked open.
- A mark on content that scrolls under a sticky header draws over the
  header.
- The last of a page sits under the note bar when scrolled to its end.
- An element moved by a CSS animation alone is followed at its next
  report, not during.
- Marks and notes are memory only, gone after a relaunch.
- In a file, a mark does not follow a code block or a wide table scrolled
  sideways inside a Markdown document, and a paragraph rewrapped by a
  narrower window moves under its mark.
- A file open in two sessions has one note between them, as it has one
  find. With both in view at once (two windows) only the newer layer is
  kept up to date.
