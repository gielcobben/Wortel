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

## Behaviour

**Double-click opens a window and focuses it.** Opening a file that already has
a window focuses that one rather than making a second. That is the entire model.

An earlier version had the window *follow* your selection, with a pin to stop it
following — Xcode's preview-tab rule. It was tried and removed: two gestures made
three states, and "why did this window change under me" is a question a preview
should never provoke. The plan argued for it; using it settled it.

**Modes: Source · Diff · Rendered**, plus images and anything else Quick Look
handles. Only Source exists so far. The mode is inferred once, when the window
opens — a file with changes opens on Diff, `.md` on Rendered, everything else on
Source — and is sticky from then on.

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
2. Diff mode, and the entry points from the Changes list and History
3. Markdown moves in — and the inspector's sharing apparatus is **deleted**:
   `InspectorOccupant.preview`, `lastMarkdownOpen`, the reclaim-the-column dance
   in `applyInspectorVisibility`, the `markdown.isOpen` checks in the toolbar,
   and the "dragged shut while a preview covered it" branch in the divider
   handler. The inspector goes back to three panes that own their column.

Then, in order, once it has earned them: ⌘F (v1.1), ⌘O quick-open by name — the
thing that makes this reachable when you don't know where the file lives, which
is the story the whole idea came from — and editing, if still wanted.
