# The preview window

A second, native window that shows one file — its source, its diff, or its
rendered Markdown — opened from wherever you already are.

The job it exists for is not "read files". It is **look at what an agent just
did, and get back**: the agent rewrites six files, you want to read one properly,
maybe nudge a value, and return to the prompt without losing your place. That
sentence decides most of what follows, including why it is an accessory rather
than a document.

## What it is not

The same kind of rule as the terminal's "no tabs, no splits", and for the same
reason — this is the feature most likely to grow teeth:

> No project search. No splits. No tabs within a document. No file management.
> One window per file, opened from where you already were.

Editing is deliberately out of scope for now. If it ever arrives it is ⌘S and
nothing else, gated behind a modification check so it can never clobber an agent
mid-run.

## Tabs

Files now open as **tabs** beside the session, in the side column, rather than
in windows: the job ("look at what an agent just did, and get back") is done with
less travel when the file sits next to the terminal. The rules below still hold,
tab for window: opening a file that already has a tab brings that tab forward,
one tab per file, and no tab ever changes its file under you. A tab's header has
the mode control and "Open in Window" for when a file deserves a window of its
own. A tab restored after a relaunch opens on the file, not a diff: where the
diff came from was a moment's state.

## Behaviour

**Double-click opens a window and focuses it.** Opening a file that already has
a window focuses that one rather than making a second. That is the entire model.

An earlier version had the window *follow* your selection, with a pin to stop it
following — Xcode's preview-tab rule. It was tried and removed: two gestures made
three states, and "why did this window change under me" is a question a preview
should never provoke. The plan argued for it; using it settled it.

**Modes: Source · Diff · Rendered**, plus images and anything else Quick Look
handles. The mode is inferred once, when the window opens — a file with changes
opens on Diff, `.md` on Rendered, everything else on Source — and is sticky from
then on. The control only appears when there is more than one to choose from: one
mode is not a control, it's a decoration costing a row of titlebar.

The three run **Diff · Source · Rendered**, left to right, each one step further
from the bytes on disk: only what changed, then the whole file, then the file as
something else entirely. Rendered goes last because it's the odd medium out —
which also leaves the two views of the same text next to each other, so ⌘1/⌘2
flip between neighbours.

**⌘1 ⌘2 ⌘3 pick a mode**, and they are *lent* by the Session menu rather than
added alongside it. ⌘1 already meant "session 1", and validation cannot arbitrate
between two items claiming one shortcut: measured, `performKeyEquivalent` stops
at the first item whose key equivalent matches and swallows the event when that
item validates disabled — it never looks for a second match, so a duplicate
further down the menu bar is unreachable. So `MainMenu.syncPreviewShortcuts`
moves the key equivalents themselves whenever the key window changes. The happy
side effect is that both menus tell the truth: with a preview key, the Session
menu shows no ⌘1 to give.

**Images render at their own size**, scaled down only when they don't fit. Quick
Look scales *up* to fill the window, which turns a 16pt icon into a wall of blur
and tells you nothing about the icon. Anything that isn't an image — PDFs, fonts,
archives — still goes to Quick Look, which knows more formats than we ever will.

**An SVG gets both modes**, and it's the only file type where that's genuinely
true: it is text you edit *and* a picture you look at, so ⌘1 shows the picture
(NSImage renders SVG as vector, sharp at any size) and ⌘2 shows the XML. It opens
on the picture — double-clicking an icon to read markup is not what anyone meant.

**Rendered Markdown is one SwiftUI view per block**, and its selection is
per-paragraph as a result — SwiftUI selects *within* a single `Text`, so a drag
can't cross a heading. ⌘A marks the whole document and ⌘C copies the file; to
select *part* of it, ⌘2 to the source, which is the same file in a view built for
selecting.

That limitation was worth one serious attempt to remove. The renderer was rebuilt
on TextKit — one `NSAttributedString`, `NSTextTable` for tables, code cards and
inline chips drawn behind the glyphs — which delivered exactly the selection
SwiftUI can't, and lost on everything else. A text engine is not a document
renderer: every card, chip, quote bar and table rule becomes hand-drawn geometry,
and some of it can't be reached at all (a code block can't scroll horizontally
while it shares a text container with the prose, so wide listings had to shrink
to fit). Three rounds of screenshots closed real bugs — `enumerateEnclosingRects`
returns *selection* rects, so a wrapped chip painted a slab out through both
margins; `paragraphSpacingBefore` applies per paragraph, and a fenced block is one
paragraph per line — and it still didn't read as well as the SwiftUI version. The
verdict is recorded here so it isn't retried by accident: **rendering quality won
over selection**, and the escape hatch is the mode switch, not a better
renderer.

**⌘F** searches whatever is on screen. It finds *lines* — the thing being
searched is a table of hand-drawn rows, not text, so `NSTextFinder` has nothing
to attach to — and it lives in the Edit menu, resolving through the responder
chain to the preview's window controller. That's what makes it live exactly while
a preview is key and greyed out everywhere else, so it can carry ⌘F without
taking it from the shell.

**Which diff depends on where you opened it from**, because the question differs:

| Opened from | Shows |
|---|---|
| A Changes row | That row's diff — staged or unstaged, as clicked |
| The file tree, or a ⌘-clicked path | Everything since HEAD (staged and unstaged) |
| A commit's file list in History | That commit's diff for that file |
| An untracked file | The whole file as additions, as the Changes list already renders it |

**Accessories, not peers.** They close when the main window closes, so quitting
behaves exactly as it does today, and they are not restored on relaunch. A
preview is a glance you took, not state worth resurrecting — and this app's
launch time is a selling point.

**When the file vanishes** — an agent deleted it, a branch switch took it away —
the content stays and the window says the file is no longer on disk. If it comes
back it reloads silently and the mark clears. Extends what
`MarkdownPreviewModel` already does on a failed read mid-rewrite: keep the last
good render rather than blanking.

## How it is built

Three things already in the app do most of the work, which is why this is
smaller than it sounds.

**`DiffView` renders both Source and Diff.** It is an `NSTableView` of hand-drawn
rows — one per line, only visible rows realized, proven on several-thousand-line
diffs. Source mode is a synthesized all-context `[DiffLine]`, so the two modes are
identical by construction: same font, same gutter, same feel, no second renderer
to keep in sync. The costs, accepted deliberately: selection is line-granular,
and ⌘F waits for v1.1.

**Highlighting needs no new code at all.** `DiffHighlighting.highlight(_ lines:)`
already segments lines by path, reconstructs the text and maps captures back per
line — hand it an all-context file and it highlights a file. Its
`maxHighlightLines` cap applies unchanged, and it already runs off the main
actor.

**Loading is `MarkdownPreviewModel`'s pattern, generalised.** That model already
solves the whole hazard: it watches the *parent directory* because "agents
replace the inode, so we watch the parent, not a file descriptor", stats before
reading so directory events for other files cost nothing, and keeps the last good
content when a read fails mid-rewrite. The preview's document loader is that,
serving every mode.

### Windows that open and can't be seen

Six separate bugs presented as "opening a file does nothing", and every one of
them was in the window rather than the click that opened it. Worth reading
before touching `PreviewWindowController`:

- **`tabbingMode = .preferred` overrides System Settings.** On a default Mac
  ("tabs in full screen only") it silently merged every preview into one window:
  same frame, only the selected one on screen. `.automatic` respects the setting.
- **One frame autosave name shared by several windows** means each new one
  restores the last one's frame, so they arrive stacked exactly. Size is
  remembered by hand instead; position cascades.
- **`NSWindowController.shouldCascadeWindows` repositions a window when shown**,
  undoing any placement made before that — and it can't do the job itself,
  because each preview has its own controller and a controller only cascades
  against windows *it* has shown.
- **`window.screen` is nil until a window has been shown**, so a placement guarded
  on it never runs.
- **A hosting controller resizes its window to fit its content**, and a SwiftUI
  root of flexible frames has an ideal size of nothing (see below).
- **`.fullSizeContentView` with no toolbar** hides the file's first lines behind
  the titlebar.

### Three things that cost a night

All three presented as "double-clicking a file does nothing", and none of them
was the thing it looked like:

- **`.onDrag` swallows the second click of a double.** SwiftUI's drag machinery
  starts tracking the mouse on the first click, so a double-click never reaches a
  tap gesture *or* an overlay that decides by reading
  `NSApp.currentEvent.clickCount` while hit-testing. Measured, the click counts a
  row saw went 1, 1, 1, 3, 4 — never 2, which is why four fast clicks worked and
  two never did. Select, double-click and drag therefore belong to one AppKit
  view (`RowClickCatcher`), the same conclusion the sidebar reached for its rows.
- **A hosting controller resizes its window to fit its content.** A SwiftUI root
  of flexible frames has an ideal size of *nothing*, so the window collapses —
  first to 1×1 when the controller is assigned, then a few points smaller on
  every layout pass afterwards (725 → 723 → 709, measured against the window
  server). `sizingOptions = []` is the fix, and it is the same idiom the
  sidebar's hosted rows already use.
- **`log` is a zsh builtin.** Every `log show` during that debugging ran the
  shell's builtin instead of `/usr/bin/log` and returned nothing, which read as
  "the code never ran" and sent the investigation after the window for an hour
  while the real fault was in the click. Use the absolute path.

### Rules it inherits

- Reading, decoding, parsing and highlighting run off the main actor. The
  terminal keeps its frame rate while a large file opens.
- Caps on size and line count, and **the window says when one bites**. A file
  silently shown to line 5,000 reads as a file with 5,000 lines — the same
  reasoning as the file tree's "N more items" row.
- Closing a window frees everything: watcher, lines, highlight spans.
- The preview shares no state with `SessionManager` and touches nothing on the
  terminal's path.

### Testable without the app shell

Following the bar the rest of `WortelTests` sets:

- binary detection, the size cap, encoding fallback
- the inferred-mode rule — changed → Diff, `.md` → Rendered, else Source
- path canonicalisation for one-window-per-file, so a symlink and a `..` don't
  quietly earn a second window for the same file

## Order of work

Within v1, the Markdown migration lands **last**, because it is the only part
that can break something in daily use — it touches the split controller, the
toolbar and `InspectorContainer`, where everything else is additive.

1. Window shell, Source mode, images, live reload — **done**
2. Diff mode, and the entry points from the Changes list and History — **done**
3. Markdown moves in, and the inspector's sharing apparatus is deleted —
   **done**: `InspectorOccupant.preview`, `lastMarkdownOpen`, `lastGitVisible`,
   the reclaim-the-column dance, the `markdown.isOpen` checks in the toolbar,
   `MarkdownPreviewModel`, `MarkdownPreviewPanel`, and `observePreviewSession`.
   The inspector is three panes that own their column.
4. ⌘F — **done**.

Left, in order, once they've been earned: **⌘O quick-open by name** — the thing
that makes this reachable when you don't know where the file lives, which is the
story the whole idea came from — and **editing**, if still wanted: ⌘S and nothing
else, gated behind a modification check so it can never clobber an agent mid-run.
