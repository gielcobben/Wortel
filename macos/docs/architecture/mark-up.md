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

It is built for every preview. **What exists today is the page in a browser
tab.** Source, a diff, rendered Markdown and an image are the next stage, and
need only an adapter each (see "One layer, an adapter per kind of preview").
The decisions and what was weighed are in `../../docs/decisions.md`
(2026-11-25, under Files, previews, browser).

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
| A page | `WKWebView`; WebKit scrolls it in another process | `WebMarkupSurface`, built |
| Source, Diff | `DiffView`: an `NSScrollView` over an `NSTableView`, fixed row height | Next: rows, exact in the same frame |
| Rendered Markdown | A SwiftUI `ScrollView` over a `LazyVStack` | Next: a block and an offset in it, since document coordinates drift as the lazy stack measures blocks |
| An image, an SVG | `NSImageView`, scaled down to fit, no scrolling | Next: the picture's own proportions |
| A PDF, a font, an archive | `QLPreviewView`, closed to us | None. No button there |

A mark (`Mark`) is tied to something of the preview's, and its shape is kept
in that thing's own units from its origin: `.thing` is the whole of a picked
element, `.area(box:ink:)` a drawn area and its ink. `MarkPlacement` says
where that thing is now (origin, size, the points per unit, and the part of
the view it may show in), and the layer and the pictures both draw from it.
So a mark moves and zooms with its content with no arithmetic of its own.

**Everything an adapter registers is added in `activate` and removed in
`deactivate`.** That rule is what makes "off costs nothing" checkable.

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

## When it ends

There is no lock on the header. When what was marked up goes elsewhere,
mark-up ends and the marks and the note are dropped (`MarkupSession.end`):
a new address or a route change (`webView.url`), a load committed
(`didCommit`, which a reload is), Page · Source, the page's process dying,
the tab closing. One rule covers what the person does and what a page does
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

The bar is `MarkupNoteBar`: an `NSTextView` on an explicit TextKit 1 stack
over the session's `NSTextStorage`, so undo, spelling, dictation and input
methods are the system's. It has its own `UndoManager`, for the reason
`CommitMessageEditor` gives, and takes ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z itself, since
those are the terminal's in `wortel.conf` and not on the menu. Return
copies, ⇧Return and ⌥Return make a line, Esc drops a stroke in hand and
otherwise leaves. Pasting is plain text only, and Writing Tools are off: both
would put a chip in the text with no mark behind it, or take one out.

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
  8pt of room, clean. A drawn area's has its ink on it.
- `whole.png` is the whole page with every mark and badge drawn on it
  natively (`MarkupPicture.whole`), 1,600 pixels wide at most. Past 12
  screens tall it is the stretch from a screen above the first mark to a
  screen below the last, and the line says "The part with the marks".
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
- The note bar's material and shadow, and its default button's accent. The
  bar and the marks were rendered off screen and looked at, light and dark,
  at 260, 384 and 640pt; such a render draws an inactive window, so it shows
  the content and not the material.
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
