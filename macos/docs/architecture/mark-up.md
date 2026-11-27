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
protocol**, never only a default in an extension of it. A member that is
only in an extension is the adapter's own when the adapter is held by its
type, and the extension's when it is held as `any MarkupSurface`, which is
how the layer holds it. `attach(to:)` was such a member: the file
adapters' tests called them by their type and passed, and in the app no
mark on a file was tied to anything (found by the owner's hand,
2026-11-25, and then reproduced with the layer mounted the way
`PreviewContent` mounts it). The tests hold every adapter by its protocol
now. Since 2026-11-26 the protocol has no extension at all: an adapter
with nothing to do for a requirement says so in a line (`attach(to:)` over
a page, `reveal` over an image), every adapter answers the sixteen in the
order the protocol lists them, and one left out does not compile.

## Where things are

All of it is in `Wortel/Markup/`.

| For | Look in |
| --- | --- |
| What a mark is, where it is now, what is written down about it | `Mark.swift`: `Mark`, `MarkPen`, `MarkupTool`, `MarkPlacement`, `MarkReveal`, `MarkDetails`, `MarkText` |
| A stroke's geometry: click or drag, each pen's points and line, its area, a drawing's handles and what dragging one does | `MarkStroke.swift` |
| A mark drawn into a picture, a chip's colours, where a badge sits and when it is a pin, the picture of the whole | `MarkDrawing.swift`: `MarkDrawing`, `MarkBadge`, `MarkupPicture` |
| On and off, which marks exist, the note's text, Return | `MarkupSession.swift` |
| What is copied, and where its files go | `MarkupNote.swift`, `MarkupStore.swift` |
| The layer coming and going, its layout and the bar's place, the marks kept on their content, pins, scrolling handed on | `MarkupOverlayView.swift` |
| The pointer, the outline of what a click would pick, the press, Esc | `MarkupOverlayView+Mouse.swift` |
| A click picked, a stroke drawn, tied and pictured | `MarkupOverlayView+Marking.swift` |
| The Move tool: carrying, selecting, resizing | `MarkupOverlayView+Move.swift` |
| One mark on screen, and the selection's outline and handles | `MarkLayer.swift`, `MarkSelectionLayer.swift` |
| The note bar: its card, the tools, Copy | `MarkupNoteBar.swift` |
| The note's text view and its layout | `NoteTextView.swift`: `NoteTextView`, `NoteLayoutManager`, `NoteLines` |
| A chip | `MarkChip.swift`: `MarkChipAttachment`, `MarkChipCell`, `MarkChip` |
| The header's button, and the layer's mount over a file | `MarkupButton.swift`, `MarkupOverlayHost.swift` |
| What an adapter answers, and the words it answers in | `MarkupSurface.swift`: `MarkupSurface`, `MarkTie`, `MarkPick`, `MarkCapture`, `MarkupWhole`, `MarkupCanvas` |
| A page | `WebMarkupSurface.swift`, `WebMarkupScript.swift`, `WebMarkReport.swift` |
| Source and Diff, rendered Markdown, an image | `LinesMarkupSurface.swift`, `BlocksMarkupSurface.swift`, `ImageMarkupSurface.swift` |
| What those three share: where they find a file's views, how they hear one move, what the two over a scroll view ask of it | `MarkupViews.swift`: `MarkupViews`, `ViewWatch` |
| Pictures of the app's own views | `ViewPicture.swift` |
| A mark's row or block known again after a rewrite | `MarkAnchor.swift` |

The tests are `WortelTests/MarkupTests.swift` (the parts with no window in
them), `WortelTests/MarkupFileTests.swift` (the file adapters against
the real views, in a window that is never shown) and
`WortelTests/MarkupOverlayTests.swift` (the layer, its bar and its session
over a preview that answers as the test says, the mouse handed to the
layer). A tested file is listed
in the test target in `project.yml`.

## A page

`WebMarkupScript` runs in a content world of Wortel's own
(`WebMarkupSurface.world`). It only reads, and scrolls when a mark is to be
brought into view: no element is added to the page, no attribute set. It
says what is under a point (through same-site frames and open shadow
roots; a frame from another site is one thing), remembers the element a
mark is tied to, and posts where those elements are whenever that may have
changed: a scroll anywhere in the page (one capturing listener a
document), a resize, the page changing itself (a `MutationObserver`, at
most once a frame). It listens only between `start`
and `stop` and posts nothing while there are no marks. A report is a flat
list of numbers, read by `WebMarkReport` as if it could be anything.

**A page moves things with no word of it.** A transition or an animation
runs for its length with no event a step, and a picture that arrives late
pushes down what is under it; neither is a scroll, a resize or a mutation.
So whatever begins or ends such a move starts a look every frame
(`follow`): a transition's or an animation's own events, a `load` anywhere
in the document, a scroll (which is what most often sets a page moving),
turning mark-up on, and a mark being made. The look posts only when a
mark's place changed, goes on while an animation with an end is running
(`document.getAnimations()`, so a script's own animation counts) and for
400 ms after the last change, and then stops. The page itself growing or
shrinking is heard too (a `ResizeObserver` on the root), which is how
something arriving late is noticed when no mark is on it. Each mark's
element is watched for its size as well, and stops being watched only when
no mark is left on it (`release`): two areas over one paragraph share it,
and moving one of them away stopped the other hearing it (2026-11-26).

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

**A drawn area follows the block under its middle**, not the element that
holds all of it (`blockUnder`). The element that holds an area whole is
often the whole column, and the column stays where it is when the text in
it moves: a paragraph added above, a picture arriving, the text set larger
or wrapped by a narrower window. Between two blocks the area takes one a
quarter of the way in from a side. A word in bold or a link is a run of a
line and not a block, so the paragraph is taken; a picture in a line is a
box of its own. Never a block inside a box that cuts off (a scrolling
panel, a frame) when the area reaches out of that box: it would be cut off
with it. What is copied still names the element that holds the area whole
and what lies inside it.

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

**Turned on again, no mark is drawn until the page has said where it is
now** (`WebMarkupSurface.activate` forgets the last report). What the page
last said is from before mark-up went off, and it has scrolled since.

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
- A reload owed for a changed file waits (`fileChanged`, `reloadWhenShown`,
  `holdsReload`) until mark-up is off and the note has nothing in it that
  was not copied (`MarkupSession.hasUncopied`). A reload drops the note,
  and this one would do it mid-sentence, or after Esc, for an edit nobody
  at the page asked for. After a copy it runs at once: the agent was
  handed the note to edit the file, and the page shows what it did.
  A load that commits is the page anew, so whatever reload was owed is
  done with (`didCommit`), and none starts while a load is under way. A
  new address is heard before its load starts (measured 2026-11-26 in
  WebKit: a link, Back, a typed address), and mark-up ended there let go
  of the reload it held, which then started in the middle of the next
  page's load (found in review).
- ⌘+ and ⌘R still reach the page with the keyboard in the note
  (`BrowserTabs.page(holding:)` counts the note as its page's). ⌘[ and
  ⌘] do not: they are Back and Forward only with the keyboard in the web
  view itself (`AppDelegate.historyBrowserPage`), and from the note move
  between areas, as from anywhere else. A step back from the note ended
  mark-up and dropped a note that may never have been copied (found in
  review, 2026-11-26).

## A file

One mount covers a file tab, a preview window and a page's source:
`PreviewContent` lays `MarkupOverlayHost` over its content, under the find
bar, while its session is on (and not over a tab kept built behind the one
in front). SwiftUI places the layer here, over views SwiftUI also places, so
a file's adapters convert through the layer (`attach(to:)`) and assume no
shared origin.

**A view emptied under its marks keeps the note in sight.** The layer is
over the view of the file it was turned on in for as long as mark-up is
on (`MarkupSession.isShown(over:)`), also once that view has nothing
left to mark: a diff the agent emptied by putting the file back, a file
cleared. Its marks have no place there, as a deleted line's mark has
none (`MarkupViews.emptied`), and the note, the tools and the header's
button stay (`isOffered(over:)`), so Esc or the button turns it off
where it is. The layer showed only while there was something to mark,
and nothing turned mark-up off when there was not: the bar, the marks
and the button went, mark-up stayed on behind them, and the next view
of the file dropped a note nobody could see (found in review,
2026-11-26). A diff also has nothing to mark for the moment it is read
again after every rewrite of the file (`diffLoaded` is false), and the
layer was taken down and made anew each time; it stays now. Shown by
`MarkupFileTests` with a real repository and document, against the old
rule and the new.

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
  of a diff, not the number) and what the four rows either side of it held
  (`MarkAnchor`), and after a change looks for that row within 400 either
  way. Code is full of lines that read the same, so of the rows that hold
  what the mark's did, the one whose neighbours agree most is its row,
  then the nearest. Where several hold it and none has a neighbour left,
  the mark has no place: a guess would put it on the wrong line. A line
  that is gone has no place either; its chip and picture stay, and it is
  found if the line comes back. A mark looks for its row when the rows
  change and when its layer comes back (`activate`), since the file may
  have been rewritten while mark-up was off. The whole file is pictured
  by scrolling the table a screen at a time and putting the scroll back,
  all in one turn of the run loop, so nothing on screen moves
  (`ViewPicture.tiles`). As wide as the view, so one very long line does
  not shrink the rest.
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
  not drawn, which is right: it is out of view. A block is known again
  after a rewrite the way a row is (`MarkAnchor`, 60 blocks either way),
  and looked for when the blocks change and when the layer comes back.
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

## Off, something changes, on again

The owner's report (2026-11-25): mark-up turned off, a scroll, mark-up on
again, and sometimes the marks were not where they belonged. Turning it
off takes the layer and the adapter's observers away, so whatever changes
meanwhile is heard by nobody. A scroll alone was not it. Measured for
every kind of preview, a scroll while off (40pt, a screen, out of view and
back, at the top and far down, glided and jumped) left every mark on its
content within 0.5pt from the first frame the layer drew. What did move
marks, each measured the same day in throwaway harnesses (the real views,
adapters and layer in a clear window; the ink read from the layer's own
sublayers at the end of every turn of the run loop, which is what the
window server is told; the content found again by its pixels in a picture
of the preview, or for a page by asking the element):

| Kind | What happened while off, or on | Before | After |
| --- | --- | --- | --- |
| Source | 3 lines added above the marks while off | 57pt (3 rows) above their lines, for good | on them |
| Source | The same while on | 95pt (5 rows) above: another line that read the same | on them |
| Source | 2 functions removed above, while on | 228 and 266pt below | on them |
| Markdown | 3 paragraphs added above while off | 226 and 395pt above their paragraphs, for good | on them |
| A page | A paragraph added above two drawn areas | 76pt above their words | on them |
| A page | A picture arriving late above them | 180pt above | on them |
| A page | ⌘+ to 1.5 with drawn areas 1,500pt down | 195 and 209pt off their paragraphs | on them |
| A page | The window made narrower | up to 204pt off | on them |
| A page | A fixed header sliding away over 300 ms | its mark left 30pt off | follows it |
| A page | The same, mark-up turned on 60 ms into the slide | 10pt off, for good | follows it |
| A page | A button moved 50px by a CSS animation, or by a script's after a scroll | 50pt off, for good | follows it |
| A page | A scroll while off, on a page whose main thread is busy | 40pt off for a frame (17 ms), then right | not drawn, then right |
| An image | A resize, a tab behind another, the view made anew | on it | on it |

"For good" is until the next scroll or change that happened to be heard.

Three causes, and what changed:

- **A file's marks were not looked for again when the layer came back.**
  The adapters only heard of a rewrite while they were listening. After a
  copy mark-up is off with the note kept, and the agent that was handed
  the note edits that very file. For Markdown the document says where its
  blocks are before the new layer is in its window, so nothing was heard
  after either. Now `activate` looks for every mark's row or block.
- **A row was known by its text alone.** In code the nearest line that
  reads the same is often another one. Now by its neighbours too
  (`MarkAnchor`).
- **A page was only asked when it scrolled, resized or changed itself.**
  It moves things without doing any of those, and a drawn area was tied
  to whatever held all of it, which is often the column. Now the script
  looks while something moves (`follow`), an area follows the block under
  its middle, and the last report is forgotten when mark-up is turned on.

Two traps for the next person. A fixture whose lines all differ: the first
tests numbered their lines, every one unlike the rest, and a mark found
its line every time. And looking for this in the scroll: what changes
while mark-up is off is the file or the page, and a harness that only
scrolls finds every mark in its place.

Also checked, and right before and after: the type size changed while off
(the same placement as changed while on, for source, Markdown and a page),
a tab kept built behind another and one made anew, a file rewritten while
on, scrolling with mark-up on a step at a time (Markdown in 25pt steps and
in jumps of thousands of points, source in 13pt steps: 0.2pt at most, one
turn of the run loop after each step), and a document with pictures in it.

## When it ends

There is no lock on the header. When what was marked up goes elsewhere,
mark-up ends and the marks and the note are dropped (`MarkupSession.end`):
a new address or a route change (`webView.url`), a load committed
(`didCommit`, which a reload is), a load that failed (the page is behind
a notice then, where mark-up could be neither seen nor turned off),
Page · Source, the page's process dying, the tab closing (its source's
mark-up with it: an open note's folder is one the sweep skips); and for
a file, another of Diff · Source · Rendered
(`PreviewContent`, and `MarkupSession.prepare`), its tab or window
closing. A file rewritten on disk is not elsewhere: the marks stay, each
where its line or block now is, and a diff emptied by it keeps its note
(see "A file"). One rule covers what the person does and what a page does
by itself, which nothing could lock anyway.

A new fragment alone is not a new address (`BrowserAddress.isElsewhere`).
WebKit reports a new fragment, `replaceState` and `pushState` only as a
new `url`, never as a load (measured 2026-11-26), and a docs site
rewrites the fragment as the page scrolls past its headings: without
this, scrolling with mark-up on ended it. A new path or query ends it.

Esc and a copy only turn it off (`turnOff`): the note is kept, and turning
mark-up on again finds it. ⌘A then ⌫ in the note clears it.

Turned off over a page, the layer fades out (`leave`) and is in its window
for that moment, taking no click (`isLeaving`: no hit, no press). A click
on the page then came to the layer, was swallowed, and picked an element
for a mark the session would never add, which the page's script kept
(found in review, shown in `MarkupOverlayTests`, 2026-11-27).

A copy still being made when mark-up ends lands nowhere, even once a
newer copy has started: each copy takes a number and `end` moves it on.

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
is drawn as the system's default button and is pressed by no key
(`CopyButton`): Return is the note's. As the default button it took Return
from the whole window, since the key window offers every key to its views
before the first responder and a key that climbs the responder chain to the
window presses its default button, so Return in the address field, the find
field or a terminal in another split copied the note instead (found in
review, shown with the real bar in a harness, 2026-11-26). The bar floats 16pt from the preview's
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
(`MarkupSurface.reveal`). A new mark's chip goes in after what is
selected, never in place of it: a drawing is not typing, and with a chip
selected it would otherwise delete the mark that chip stood for (found by
the first trial of the click, 2026-11-25).

What is brought into view is **the mark's own box, into the part of the
preview the note bar leaves showing** (`MarkReveal`): the layer passes how
much of the bottom the bar covers, from the bar's top down. A mark wholly
there already does not move. One that is not is centred in that part; one
larger than it shows its top-left. A page does this in its script, in each
scrolling box and same-site frame around the mark and then the window,
eased (at once with Reduce Motion), and counts a fixed or sticky header or
footer the mark is not inside as covering what is under it. A table and a
document scroll at once. A Markdown block that is not built has no frame:
the document's scroll reader takes it to the middle
(`MarkupViews.revealBlock`, not eased), and the mark is placed exactly when
the block reports its frame, within a second of the click.

The first version brought the thing a mark is tied to into the whole
view: a page `scrollIntoView` on the element, a table the row a third of
the way down, Markdown the block to the middle. Measured with the real
views and a real mouse-down on the chip (2026-11-25), that failed in four
ways. A box drawn on a page was then tied to the element that holds all
of it (it now follows the block under its middle, see "Off, something
changes, on again"; the box's own place is still what is revealed),
here a 3,512pt article, and centring that left the box 350 to 1,300pt
above the view, even when it had been in view. A mark under the note bar,
or under a page's fixed header, was inside the view and nothing scrolled
(a paragraph 10pt under a 48pt header; a line's mark wholly under the bar).
A table's mark over eight lines whose first line showed was left with the
rest under the bar, and Markdown centred a 1,262pt code block with the
mark near its foot 300pt below the view. And a page's element hidden in
its scrolling box or frame while the box was on screen counted as in view.
Not causes, measured the same day: a resize (the page is measured at the
click), page zoom 1.5, a second click while the first scroll eases, and
the click itself (a chip is hit at both edges, on any line of the note).
An eased `scrollTo` for an unbuilt block was tried and dropped: it went on
past the exact placing and left the mark 130pt lower.

After the change, over a page (a fixed header, a scrolling panel, a frame,
800 and 420pt wide, zoom 1 and 1.5), a source table and rendered Markdown
(700 and 460pt), every mark ended inside that part, centred within 2pt
where it moved, and a mark already there did not move. A Markdown block
not built was in place 8 ms after the click. Those are off-screen
windows with events handed to the views; how the eased page scroll looks
under a hand was not seen.

**A selected chip looks like a selected token**, as Mail's address tokens
and `NSTokenField` do: solid in its mark's colour, its number and name on
it, and no selection painted behind or around it. The system's selection
was a block of the line's height and the chip's width with its gaps, with
the capsule floating in it; the owner did not like it. A chip is drawn by
its own cell (`MarkChipCell`), which asks the text view whether its
character is selected, and the note's layout (`NoteLayoutManager`) clips
the chips out of every selection fill, so words in the same selection
keep the system's highlight. This holds for a chip clicked alone, a
dragged or Shift-arrow range with words in it, and ⌘A. A change of
selection, of first responder or of key window redraws the chips it
touched (`NoteTextView.setSelectedRanges`), since a cell is not drawn
again for a change of selection alone. What selection means is unchanged:
typing replaces a selected chip and ⌫ removes it.

The colours are `MarkDrawing.chip(_:selected:emphasised:)`, pure and
tested. Selected where typing would go: the mark's colour, solid, with
white words where white has 3:1 on it and near-black where it does not.
Measured on macOS 27, light and dark: white is 3.2 to 4.2 on red, blue,
purple and pink, and 1.9 to 2.3 on orange, green and teal, which get
black (over 9). No mark colour reaches 4.5 with white. Selected in a window
that is not key, or with the keyboard elsewhere: the fill at 40% with the
label's colour for the words, as the system dims a selection it is not
acting on (at 50%, white on orange, green and teal in the dark was under
4.5 over the bar). One trap found on the way: `fillBackgroundRectArray`
hands over the layout manager's own scratch array, and asking it for a
chip's rect first wrote over the selection's rects, so the selection was
filled over that chip alone. The rects are copied before anything else.

**The pointer over a chip is the arrow**, since a chip is clicked and not
typed into; over the words and the gaps between them it is the I-beam
(`NoteTextView.cursor(at:)`). It is set on every move over a chip, and the
text view's own handling of the move is skipped there, since that is what
would put the I-beam back. The arrow covers the chip's 3pt clear edges
too.

A chip has 3pt of clear room either side, as part of itself, so two chips
or a chip and a word do not touch. A chip that starts a line has none
before it (`MarkChipCell.cellFrame(for:…)`, which the typesetter asks with
the chip's place on the line), so its capsule starts where the words of
the other lines do; with the room it stood 3pt in from them, which the
owner saw. The text is lifted to the middle of its
line: a line is 22pt to hold a chip, the caret is as tall as the line, and
with the text at the line's foot the caret stood well above it.

**Every line has its baseline where a line of words has it**, 19pt from
the line's top before the text's 3pt lift (`NoteLines`, the layout's
delegate). The typesetter put a line with a chip on it 3pt higher, at 16,
though the line stayed 22pt: the
chip counted as taller than the words. The words on that line rose with
it, so in a note of several lines the gaps between lines of words were
25pt after a chip's line and 19pt before one, the chip touched the line
above (it stood 1pt over its own line's top), and the caret, drawn at the
middle of the line, was 3pt low against the words. Measured with the real
bar in an off-screen window on 2026-11-26, before and after: every line's
words 16pt down from its top, every chip from 2pt under its line's top to
its foot, so two chips one above the other are 2pt apart (they were half
a point).
A chip's own words sit on the sentence's baseline; they were a point
under it. The system's `NSTokenField`, drawn the same way as a reference,
keeps its lines evenly spaced with tokens on them, and stands a token
that starts a line about 4pt in, which here was the thing seen as wrong.

The bar's padding was measured too and left as it is: the first line's
box starts 14pt under the bar's top (its words' ascenders at 17.6, a
chip at 15.4), the tools start 8pt under the last line's box, and they end
10pt over the bar's foot, where their glyphs end about 17pt over it, which
is what the eye compares with the words above.
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
those are the terminal's in `wortel.conf` and not on the menu. Return in
the note copies, ⇧Return and ⌥Return make a line, Esc goes back one step (see
"The tools"). Pasting is plain text only, and Writing Tools are off: both
would put a chip in the text with no mark behind it, or take one out.

Nothing can be dropped into the note, which is what keeps a chip from
being dragged into words. A text view takes a drop only in a type it both
reads and lists as a drop type, and the note reads words as
`public.utf8-plain-text` where the system's list names them by the older
`NSStringPboardType`. So a selection with a chip in it, dragged within the
note, slides back; dragged out it is words, as ⌘C makes them. Checked on
2026-11-27 with the real bar, its own `dragSelection` and drop methods:
nothing changed. With drops let in, the chip landed as its name and its
mark was gone, so a change that lets drops in has to carry the chip.

The undo stack outlives a bar while another bar is on the note. A tab
moving rows has its new layer up before the old one goes, and the old
bar's going cleared the undo the new bar was already using. A text view's
undo edits the text through whichever text view is on it when it runs:
measured 2026-11-27 with two text views on one text and zombies on, undo
went through the second after the first had gone and asked nothing of the
first. The last bar to go still clears it.

## A mark that has left the view leaves a pin

A badge sits on its mark's corner, and is held inside what the mark may
show in (`MarkBadge.spot`). While any of the mark shows, it is the circle
it always is, at the edge if the corner is past it. Once none of the mark
shows, the badge stays at the edge the mark left by and becomes a pin: a
drop, the circle with a point (`MarkBadge.point`, drawn under the badge by
`MarkLayer`), 15.5pt from its middle to its tip and 3pt clear of the edge.
The point is toward the nearest of the mark, not its corner, so a mark
straight above is pointed straight up at however wide it is, and one
inside a box that scrolls sideways is pointed at sideways.

A press on a pin brings its mark into view, with any tool in hand: the
same `reveal` a chip's click asks for. So a drawing cannot begin on a pin.

A pin for a mark below the view is kept above the note bar, which floats
over the foot of the preview: under the bar it pointed at nothing anyone
could see. Only the ink is cut off where its content is (`MarkLayer`
cuts a sublayer of its own); a badge is always whole. Where what the mark
may show in is too small to hold it, 37pt each way for a pin and 20pt for
a circle, the badge stands in as much of the view round it as it takes,
above the bar where there is room (`MarkBadge.spot`, `seen`). A mark in a
box that clips, a card or the window drawn on wortel.sh, leaves with its
box: what was left of the box at the top of the view was a strip a few
points tall, the pin in it showed its point and not its number, and once
the box had gone there was no pin at all (the owner, 2026-11-26). Measured
then over the built site and a fixture page, 900 by 700 and 1400 by 900,
light and dark: a mark in the hero's window with the stage's last 8pt at
the top, and with the stage gone, a pin cut to 0% before and whole after;
a mark in a 180pt card that clips the same; marks on a fixed header, a
sticky heading and the page itself unchanged. And pins that would sit on one another are lined up side by
side along their edge, the lowest number keeping its place
(`MarkupOverlayView.spreadPins`): marks drawn down one side of a page all
leave by the same place, and a pile of pins shows one number.

Circles at the edge were what there was first. Scrolled past a few marks
they were a row of dots along the header that said only that marks were
somewhere (the owner, 2026-11-25, who asked for a drop). The shape was
drawn to a picture at every angle and looked at: sides that leave the
circle along the circle's own direction, so there is no shoulder, and
arrive at the tip from outside the straight line to it, so the drop is
full and not a flame. Not seen in the app. The pictures that are copied
keep circles: nothing is out of view in a picture.

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
  the pen's solid 3pt line with 4pt corners. It was a 2pt dashed line for
  a day, to tell it from a picked element's solid outline; the owner saw
  both and kept the solid line (`docs/decisions.md`, 2026-11-25). What
  still tells the two apart: a picked element's outline is 2pt and sits
  just outside the element, and its badge is on the element's corner; a
  box is 3pt, drawn where the hand put it, with its badge where the drag
  began.
- **Shift straightens** the pen, the highlighter and the arrow: a line in
  steps of 45 degrees. It does nothing to a box being drawn: an area does
  not need to be square, and a rectangle says it as well (the owner,
  2026-11-25). Resizing a box by a handle is different: there Shift keeps
  its proportions, as it does everywhere on a Mac.
- **A mark is called by what it was drawn with**: "area 2", "box 3",
  "arrow 4", "highlight 5", on its chip and in what is copied, and
  `details.json` has it as `shape`.
- **A click still picks an element** of a page with any pen in hand. Only a
  drag draws.
- **A click on an element already picked makes no second mark.** Its chip
  is selected in the note instead (`MarkupNoteBar.selectChip`, scrolled
  into view in a long note), and no number is used: the overlay takes one
  before it asks and gives it back. The overlay names the picked marks
  whose chips are in the note (`MarkupSurface.pick(_:at:unless:reply:)`),
  the script answers `{already: n}` when the clicked element is one of
  theirs, and the adapter turns that into `MarkPick.already`, trusting
  only a number it asked about. Only picked marks count: a drawing is tied
  to an element too, as its anchor, and that element can still be picked.
  A picked mark whose chip was deleted does not count either, so its
  element can be picked again. No reveal: the element was just clicked
  where it is. Checked 2026-11-25 with the real adapter and script over a
  fixture page: the button clicked twice is one mark and the next number
  is still 2, with chip 1 selected; a paragraph with a box drawn on it is
  picked as a new mark, and a second click on it selects that chip; the
  button picked again after its chip was deleted is a new mark.
- **Move** takes a drawn mark by anywhere in its box and carries it. Let
  go, it is tied again to what is under it there (the same call that tied
  it first) and pictured again; it keeps its number and its chip. A picked
  element is not moved: it is where its element is. With Move in hand the
  pointer is the arrow, and a hand over a drawing. While it is carried,
  what moves under it moves under it: the drawing stays with the pointer
  and is let go where it was drawn (`MarkupOverlayView.held`, which
  `place` leaves alone). It jumped back by however far it had been
  carried whenever the marks were placed again mid-drag, a page's report
  or the note growing a line, since setting a transformed layer's frame
  takes the transform off its position; and let go after the content had
  moved, it landed where the content took it (found in review, shown in
  `MarkupOverlayTests`, 2026-11-27).
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
  and tested; the layer only hands the mouse to them
  (`MarkupOverlayView+Move.swift`). The selection is a layer of the
  overlay (`MarkSelectionLayer`), placed again whenever the marks are, and
  is in no picture.
- **Esc goes one step at a time**: what is in hand (a drawing being
  carried, a handle, a stroke) is put back, then the selection is
  dropped, then mark-up is left (`MarkupOverlayView.stepBack`).
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

Tried and taken out (2026-11-26): the pen making a rough loop, box, line
or arrow a clean one on letting go, as Preview's Sketch pen does. It
worked for 94 real loops in 100 at best, and a shape that comes
sometimes is worse than one that never does. What was measured and why
it went is in `../../../docs/decisions.md`.

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
- A picture's name is never used twice in a note's folder: a drawing moved
  is pictured again as `3-2.png`, and so is a mark that is 1 again after
  every chip was deleted. A path once copied shows what it showed.

`MarkupStore` puts them in `~/Library/Caches/<bundle id>/Markup/<day>/<n>/`:
no space in the path, no folder macOS asks permission for, and none it
empties by itself. A test copy has a bundle id of its own, so a folder of
its own. A note's folder is removed seven days after its last write, at
launch (with the pasted images) and whenever a new note's folder is made;
the folders of notes still open are skipped. Removed, not moved to the
Trash. Every sweep runs on `MarkupStore.queue`, the one the pictures are
written on. A note's folder is made on the main thread, and makes its
day's folder again on every try, since a sweep removes a day it finds
empty and a day just made is empty until its first note is in it.

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
page's listeners included. A layer put back in a window takes up again
exactly what it let go of (the note's text in its text view, the frame it
follows); the first version took up neither, and a layer put back showed an
empty note that took no typing and no new marks. What stays is the note's text and the names of
its pictures. Off, with a note kept, the page's script holds which elements
the marks are on and nothing runs.

There is no repeating timer anywhere in it. A page's script asks for a
frame at a time while something in the page moves and for 400 ms after
(`follow`), with mark-up on and a mark made; a page that is still is not
looked at.

## Not verified

- The off, change, on measurements above in the app itself. They are from
  harnesses that mount the real views, adapters and layer; scrolls were
  made by setting the scroll position, not by a hand, and the app was not
  driven. Whether the owner's report was one of the causes found is not
  known: none of them needs a scroll.
- How long a real site keeps the page's script looking (`follow`). On the
  fixture it stops 400 ms after the last move.
- A drawn area's block in a page with frames from its own site and shadow
  roots: the code goes through them, and only a plain document was
  measured.
- How the marks follow a page under a hand: a trackpad, a wheel mouse,
  momentum, the bounce at a page's end. The numbers above are from events
  handed to a web view in a clear window.
- The crosshair over a page that sets cursors of its own, and that the
  page stops lighting what the pointer passes.
- Return while an input method is composing (Japanese, Pinyin).
- Return typed in a key window. That the address field, a terminal and a
  view that hands keys on no longer copy was shown by asking the key
  window's key-equivalent pass and its responder chain directly, in a clear
  window that is not key, not with a typed key.
- A layer taken out of its window and put back by the app itself. The
  harness moved the real layer's container out and back, into the same
  window and another; no path in the app that does so was found or driven.
- The note bar's default button's accent, its caret and the pointer over
  it: each needs a key window or a real pointer. The bar and the marks were
  captured as really drawn on macOS 27 over a paragraph, light and dark, at
  260, 384 and 640pt, and its corner looked at enlarged; such a capture is
  of an inactive window.
- The pointer over a chip. Which cursor the note would set at a point (a
  chip, its clear edge, a word, a gap, past the line's end) was checked in
  the real file mount on 2026-11-25; the pointer itself, and that it does
  not flicker, need a real pointer in a key window.
- A selected chip in a key window. Captured as really drawn on 2026-11-25,
  light and dark, a chip alone, a range of two chips and the word between,
  ⌘A, and the selection moved off a chip; the solid look only with a
  window that answers `isKeyWindow` with yes, since a capture's window is
  not key.
- The note's even lines with an input method's text being composed, and
  the blinking caret beside a chip that starts a line. The layout was
  read back and captured on 2026-11-26 (a line, the owner's two lines, a
  note that starts with a chip, six lines, a chip selected, ⌘A); nothing
  was typed by a hand.
- That Claude Code and Codex each read a picture from the cache folder
  without asking.
- In the app, as of 2026-11-26: ⌘[ from the note moving between areas, a
  held reload not starting after ⌘R or a link, and the note over an
  emptied diff. The first two were read through and the WebKit order
  measured in a harness; the third is tested with a real document but not
  with the layer drawn over it.

## Known limits

- A frame from another site is picked as one thing.
- The note takes the keyboard, so the page sees a blur: a menu that closes
  when the page loses focus cannot be marked open.
- A mark on content that scrolls under a sticky header draws over the
  header.
- A chip's click cannot bring a mark into view inside a frame from another
  site, or past the side of a view that does not scroll sideways (a box
  drawn in a wider window): it is moved up or down only.
- The last of a page sits under the note bar when scrolled to its end.
- A script's own animation that nothing announces (started by a timer:
  no scroll, no change to the page, no event) is followed from the next
  thing that is heard, not from its start. Measured 2026-11-25: a button
  moved 50px that way keeps its mark 50pt off until then.
- A mark on a line or a block that reads the same as others, with every
  neighbour rewritten too, is not drawn.
- Marks and notes are memory only, gone after a relaunch.
- In a file, a mark does not follow a code block or a wide table scrolled
  sideways inside a Markdown document, and a paragraph rewrapped by a
  narrower window moves under its mark.
- A file open in two sessions has one note between them, as it has one
  find. With both in view at once (two windows) only the newer layer is
  kept up to date.
