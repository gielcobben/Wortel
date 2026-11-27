# @wortel/web

The landing page for Wortel, served at **wortel.sh**.

Astro static site, deployed to **Cloudflare Workers static assets**. Fully
static (`output: 'static'`); no server runtime, no SSR.

## Develop

```sh
npm install
npm run dev        # http://localhost:4340
npm run check      # typecheck the pages and the worker; ../scripts/check.sh runs every app
```

## Build & deploy

```sh
npm run build      # → dist/
npm run deploy     # astro build && wrangler deploy → wortel.sh
npm run cf-preview # build + `wrangler dev` (serve dist through the Worker locally)
```

Deploy config is in `wrangler.jsonc` (assets first, `name: wortel-web`,
custom domain `wortel.sh`; the Worker runs only for `/ph/*` and the letter). The account/zone is shared with the app's Sparkle
feed at `updates.wortel.sh`. See the repo root `AGENTS.md`.

## Structure

```
src/
  data/site.ts             landing-page AND /docs copy: the single source
  data/compare.ts          ALL /compare copy: the apps, the questions, every cell
  data/inline.ts           the marks a sentence in site.ts may carry: `code`, a key like `⌘N`, **bold**
  data/release.ts          the newest release, read from the appcast at build time
  data/schema.ts           the homepage's JSON-LD
  content/releases/*.md    the changelog, one Markdown file per release
  content/legal/*.md       /privacy, /terms (the filename is the route)
  pages/index.astro        the homepage: sections in components/home/
  pages/about.astro        /about   the name, why it exists, a family tree, six beliefs
  pages/updates.astro      /updates the changelog: the newest release in full, every earlier one a row under its month
  pages/updates/[version].astro  /updates/<version>  one release on a page of its own
  pages/feed.xml.ts        /feed.xml the changelog as an Atom feed, linked from every page's <head>
  pages/compare.astro      /compare Wortel against nine named apps
  pages/docs.astro         /docs    commands, shortcuts, behaviour
  pages/mark-up.astro      /mark-up one feature in depth (see Feature pages)
  pages/layouts.astro      /layouts the same for splits, tabs, zoom and windows
  components/FeaturePage.astro  the layout of a feature page, from a FeaturePage in data/site.ts
  components/films/        a film more than one page shows: PanesFilm (the homepage's splits and /layouts), MarkupFilm (the homepage's section and /mark-up), ReviewFilm (the homepage's "See what it did" and /layouts)
  components/layouts/      what only /layouts shows: Windows (two windows on one stage)
  components/markup/       what /mark-up shows: Surfaces (mark-up over Markdown, source and a diff) and Tiles
  pages/release-notes/     /release-notes/<version>.html  notes for Sparkle
  pages/llms*.txt.ts       maps for language models
  pages/*.md.ts            /index.md, /docs.md, /compare.md, /mark-up.md, /layouts.md, /updates.md: pages as Markdown
  data/markdown.ts         the renderers behind those and llms-full.txt
  pages/404.astro          the not-found page (dist/404.html)
  components/home/         Hero, Start (a terminal first: a shell, an agent typed into it, the field in Settings that names it, ⌘N starting one), Agents, Panes, Markup and Review (each a section's words over a film in components/films/), Bento (Wortel at a glance: one poster of pieces of the real app, in the manner of Apple's keynote summaries), Glance (the FAQ, in the right column beside its heading)
  components/AppContent.astro  wraps a piece of the app that shows a document: its headings become plain blocks, so the page keeps one h1
  components/GitHubMark.astro  GitHub's mark, for the buttons to the source (SITE.repo) in the nav and the closing call; they open in a new tab
  components/Section.astro a section: the row it opens with (a hairline, a two-line heading at the left,
                           a paragraph and a link at the right), then what it shows
  app/gen/*.astro          the app's panes, GENERATED from the Opmaak canvas
  components/Stage.astro   a stage: the lake with the chapter tabs and play/pause over the window
  components/Window.astro  the window's chrome as the canvas draws it: glass, layout, and the corner (Running and "…")
  scripts/app.ts           tools for acting on a generated window: select a row, set a status, print a line
  scripts/film.ts          a film with chapters: autoplay, tabs, arrow keys
  scripts/hero.ts          the landing sequence (one GSAP timeline)
  scripts/panes.ts         the splits scene: one story in three chapters, each a scene (its beats, and how it ends)
  scripts/scenes.ts        the agents scene and the terminal-first scene
  scripts/markup.ts        the mark-up scene: point, say it, copy, paste
  scripts/review.ts        the review scene: Changes, History, Files and a preview, in one session
  scripts/surfaces.ts      /mark-up's second scene: the marks drawn and the note written over three previews
  scripts/bento.ts         puts the real app into the bento's tiles: parts cloned out of the generated panes (the diff, a plan, a preview being marked up, the commits, the file tree) and three windows (a terminal, a browser, one in splits)
  styles/site.css          the site's design system: READ ITS HEADER before adding a section
  styles/app.css           Tailwind + the app's own macOS tokens, scoped to .wapp
public/
  app/                     glyphs and images the generated panes use
  img/*.jpg                the four photos the windows stand on (see Photos)
  icon-*.png, favicon-*    the app icon, exported from macos/Wortel/AppIcon.icon
scripts/opmaak/            regen.sh: the canvas -> src/app/gen (through jsx2astro.mjs);
                           drift.sh and synced: how far the app is ahead of the canvas
scripts/og/                render.mjs: the inner pages' social cards -> public/og
```

### The app window is live HTML, not a screenshot

Regenerating these windows is maintainer-only: it needs the private `opmaak`
CLI, and contributors don't need it, because the generated `src/app/gen` is
committed and the site builds from it as it is.

Every window on the site is built from the Opmaak canvas "Wortel"
(https://opmaak.dev/c/2v3opz6osv), whose panes are Tailwind markup over the
app's measured tokens. To pick up a change made on the canvas:

```sh
scripts/opmaak/regen.sh --check    # what differs, changing nothing
scripts/opmaak/regen.sh            # write src/app/gen, fetch new images into public/app
```

The table at the top of that script is the whole mapping: which frame and which
layer each file in src/app/gen comes from. It needs the `opmaak` command,
signed in. A new pane is a new row there. The canvas itself is drawn by hand
from the app; `scripts/opmaak/drift.sh` says how far the app has moved since,
and the `sync-visuals` skill (`../.agents/skills/`) is how it is caught up.

The hero window is the `Window` of the "Foggy Lake" frame. Don't hand-edit
files in src/app/gen; scripts can find nodes by their `data-name`. The canvas
has a light and a dark mode of every state with identical markup, so a window
follows the page's colour scheme through the tokens in styles/app.css.

### One layout

Every page sits on one container; nothing is centred. Headings and visuals
start at its left edge, and what there is to read about a heading starts
beside it.

Every section opens with the same row, `.row12` in `site.css`: a hairline,
what the section is called at the left (`.k`) and what there is to read at the
right (`.v`), the two on one baseline. The row has two measures. On the
homepage the name has columns 1 to 5 and the text 7 to 12. On a page that is
text the row is `.row12.read`: the name is smaller (20 / 28) in columns 1 to
3, and the text has columns 4 to 11.

- **On the homepage** a section is `components/Section.astro`. The name is a
  heading in two lines, the claim in ink and its other half in grey; under it
  is the section's link, to the feature's own page (`/layouts`, `/mark-up`)
  or to the part of `/docs` that goes further; the right column is one short
  paragraph. A section that only the beta has says "Beta" over its heading,
  as the feature pages do over their name. Under the row, at full width, comes what the section shows: a
  `Stage` (a part of the foggy lake with the chapter tabs and a round
  play/pause button over the app window at its natural proportions) or the
  bento. The questions are the exception: they are a column themselves, so
  they sit in the right one (`aside`), and their heading stays beside them
  while they scroll.
- **An inner page** is `.phead` (one large line and one grey sentence, with
  the hero's own measures) and then `.row12.read` rows. The left of a row is a heading
  (`/about`, `/docs`, `/compare`), a version with its date in grey under it
  (`/updates`), or a small label (`/privacy`, `/terms`). Add `.stick` to a
  `.k` whose right column is long.

**On a phone** the rows stack: the name, then the text under it. `/docs`,
whose section names no longer stay in view beside the text, lists its
sections under the page's opening line (900px and under). A table whose first
column is something typed (`table.terms`, set by `Blocks.astro` from
`mono: 'first'`) becomes a list, the term on a line of its own: side by side,
the longest command set the page's width and the whole page scrolled
sideways. Controls are sized for a finger in one place, `site.css` under
Touch: no grey tap flash and a dimmed press instead, no wait for a second
tap, and `.tap` for a control drawn smaller than 40px.

Headings are light: weight 400, and 500 for a page's one large line. Size and
the two tones carry the hierarchy. A heading is two short lines with no full
stop, and it does not change while a film plays: the grey half used to be the
current chapter's caption, and the reader had to chase it.

Don't name a site class after a Tailwind utility (`block`, `grid`, `flex`…):
the app's generated markup uses those.

### Feature pages

A feature page shows one feature in depth: `/mark-up` and `/layouts`. It sits between the
homepage, which makes the point once, and `/docs`, which states it exactly.
It keeps the homepage's layout (the opening, then sections that open with
`.row12` over a stage or tiles) and ends in rows to read, as `/docs` does.

- **The words** are a `FeaturePage` in `data/site.ts` (`MARKUP_PAGE`,
  `LAYOUTS_PAGE`): the
  opening lines, the parts (a two-line heading, one paragraph, a link, and
  short facts), the reference rows, and where to go next. `FEATURE_PAGES`
  lists the pages: the footer, `llms.txt`, `llms-full.txt` and each page's
  "More" row read it.
- **The layout** is `components/FeaturePage.astro`. It renders the opening
  with the film in the slot `hero`, then one `Section` per part with whatever
  is in the slot named for the part's id, its facts under that (`.facts`),
  the reference rows (`.row12.read`) and "More".
- **The page file** (`pages/mark-up.astro`) only fills the slots. Its
  Markdown twin is `pages/mark-up.md.ts` (`featureMd` in `data/markdown.ts`).

To add one: write its `FeaturePage`, add it to `FEATURE_PAGES`, copy the two
page files, and give it a line in `pages/sitemap.xml.ts` and a closing photo
in `components/Footer.astro`. A film two pages show goes in
`components/films/`, one to a page: a scene finds its film by name.

How a page is paced was taken from reading other products' feature pages
(Framer's, mostly): a short opening with the product itself as the picture, a
handful of parts with one visual each, a link to the manual from a part,
never the same kind of block three times running (film, film, tiles, tiles,
rows), and a close that leads to the other feature pages before the download.
A part may carry a second tier of one-sentence facts (`facts`). `/mark-up`
had two such lists and lost them, since they repeated the paragraph beside
the film and the tile that shows the copied text; `/layouts` keeps its two,
which say what no picture on the page does.

**/mark-up** opens with the homepage's mark-up film (a page in a browser
tab), with its sidebar hidden from the start (`bare`): the terminal keeps 360
and the browser has the rest. From 640 wide the browser shows the page as
captured at a wide split (`public/img/page-wide-*.webp`, the splits film's),
and the marks are placed for that layout, from the paragraph and the button
as measured on the site at 1074 (`scripts/markup.ts`). Narrower, it shows the
narrow picture every film shows. That one is a retake of the canvas's own,
`public/img/page-narrow-*.webp`: this site at 537 by 740 points, 2x, with
the hero held (`/?t=30`). The canvas's was taken before the hero's stage had
arrived and shows an empty box under the buttons; the layout is the same to
the point, so the canvas's marks are where they were. `retaken()` in
`scripts/app.ts` swaps it in, for the mark-up film on both pages, the splits
film's browser column, and the "A click picks an element" tile. Retake all
four pictures when the hero changes. Its second film, `scripts/surfaces.ts`, does the same over three
previews in one tab's place: rendered Markdown, source, a diff. In each,
⇧⌘M turns Mark Up on, the pointer draws the marks (a box is dragged out from
its corner, a whole rectangle all the way; an arrow and a highlight are
uncovered along their length) and the sentence is typed around the chips. The Markdown chapter is the canvas's
"Mark-up, a plan" as drawn. The canvas has no frame for mark-up over source
or a diff, so those two are put together from frames it has: the source tab,
the diff out of the Changes pane, and the plan's marks, note bar, Mark Up
button and mode switch, cloned and placed over lines the script measures. A
frame of each on the canvas would replace that, and one of an image would add
the chapter that is missing. On a phone the plan wraps and its marks are
placed over the same words again, the plan moves down to a mark drawn above
what shows, and code scrolls sideways or up to a mark that would be out of
sight. The two rows of tiles lift their pieces out of the same two frames. The
second row's note is `MARKUP_NOTE` in `data/site.ts`: the bar shows it, and
the text beside it is written from it the way the app copies one, so the two
cannot disagree. Their boxes are one height: the bar's tile is the narrower
(4 to 7) so the sentence runs to about as many lines as the text, set a size
smaller (12 / 16), and whichever comes out shorter takes up the difference.

**/layouts** is made of the homepage's films. It opens with the splits film
(`films/PanesFilm.astro`), which has a fourth chapter there (`sidebar`): ⌘B
folds the sidebar away and the leftmost row gains its buttons. A window too
narrow for a sidebar has it folded already, so at 1000px and under that
chapter and its tab are left out. "Every split has its own tabs" is the
review film. "More than one window" is `components/layouts/Windows.astro`:
two windows on one stage, each with its own sidebar and sessions, nothing
playing; the one behind is not the key window, so its traffic lights are
grey. Dragging a session between windows is not shown.

### Motion and interaction

Every stage below the hero is a film with chapters (`scripts/film.ts`). A
chapter is a function that puts a real window in that chapter's state from
wherever it was, written through `scripts/app.ts` (`sb.select(…)`,
`sb.status(…, 'attention')`, `term.print('Tool', '(npm run build)', 'Bash')`)
rather than by touching markup. Chapters play by themselves while the stage is
on screen; a tab, the arrow keys, the pause button, or anything pressed in the
window itself stops that, and play picks it up again. Nothing the films do is
tied to scroll; only the photos drift a little against it (below).

The windows answer to the pointer: sessions select at once, as in the app,
folders fold, Back and Forward walk the sessions you were on, the sidebar
button, a tab's close button and Show All Splits work (splits), and the
notification and the prompt's choices work (agents).
Anything pressable is marked `data-row`, `data-fold` or `data-press` and gets
the app's own hover from `styles/app.css`. A control is found by its layer
name (`PRESS` in `scripts/panes.ts`), or by where it is when the name is not
its own (`PRESS_AT`: every tab's close button is "Close"). A split is gone
when its last tab closes, and a click anywhere else in a split puts the
keyboard there.

**The splits film** is one story in one window that only goes forward, in
three chapters named for what you do. Each is a cause and what the window
does about it, held 1.5 s on how it ends, and each starts where the one
before ended; only the loop back to the first is a cut. `scene(i)` in
`scripts/panes.ts` returns where a scene starts, its beats (what happens, and
when) and its length, so a chapter's hold is never a number kept beside the
script. The session is the one building the landing page ("Landing page
hero", in `web`), the same one the mark-up film after it picks up.
- **⇧⌘D**: the agent's terminal alone. ⇧⌘D is pressed and the window is
  two splits, the new one under it a shell in the session's folder (240 of
  the window's 704 tall, as a divider dragged down leaves it: at half, most
  of it was empty); `npm
  run dev` is typed into it and the server's output arrives. 3 s.
- **Drag a tab**: ⌘ and a click on the address the server printed opens the
  page where a browser opens by itself, in a column that slides in at the
  outer edge, half the window. Its tab is picked up and carried over the
  middle of the agent's split, which lights all over, and let go it joins
  that split's tabs in front of the agent's. The page there is a capture at
  that width (`public/img/page-wide-*.webp`, 1074 by 740 points at 2x, taken
  of this site with the hero held): retake it when the hero changes. 3.7 s.
- **Zoom**: the page has the keyboard where it was dropped. ⇧⌘↩ gives it
  everything beside the sidebar with Show All Splits lit in its row, and
  ⇧⌘↩ again shows both splits. 2.6 s.

Keys are shown the way the other films show them (`pressKeys`), but over the
split that has the keyboard, in the largest gap in what its terminal shows,
and they are gone as the app answers: they never sit on a line of text. The
agent's terminal keeps five rows clear under its last line for them
(`data-reserve`, which `fitTerminal()` in `scripts/app.ts` honours). What is
done with the mouse is done by the film's pointer (`Pointer` in
`scripts/app.ts`: 0.7 s of travel), typing is 55 ms a character. With reduced
motion the film is still on "Drag a tab" as it ends, both splits, and
each chapter shows how it ends (Zoom: the zoom). Anything the visitor presses
stops a scene where it is.

**The review film** (`scripts/review.ts`, "See what it did", after the
agents) is the same kind of story in the session whose agent has just said it
is done, "Quicker panes": the canvas's terminal, diff, commits, tree and plan
are all that session's. Four chapters, each starting where the one before
ended, held 2.4 s on how it ends so there is time to read a pane:
- **Changes**: ⇧⌘C, and the column slides in at the outer edge (384 wide)
  with the working tree and the diff.
- **History**: ⇧⌘H puts the commits and their graph in front there. The
  column's row of tabs is a tab longer in each chapter, as the canvas draws
  the three panes.
- **Files**: ⇧⌘F, the project as a tree.
- **Preview**: the pointer picks `plan.md` in the tree and Space opens it in
  a preview tab in front of the terminal, its title in italics.

Its keys show over the terminal, in the room it keeps clear above its prompt
(`data-reserve`). On a phone the stage shows the session's split or the
column, each as wide as the stage, and pans between them; the tree scrolls to
the plan's row first. With reduced motion it is still on Preview.

Rules for motion, so a new piece moves like the rest:
- Curves are `--ease-out` (anything answering the reader) and `--ease-in-out`
  (something on screen moving to a new place), both in `site.css`. No ease-in:
  it starts slow, which reads as lag. Exits are quicker than entrances.
- Answers to a click stay under 300ms (the chapter thumb is 300ms, a press
  160ms). Only the films and the landing sequence take longer.
- Tabs and columns inside a window swap at once, with a 200ms fade in, as the
  app does. Nothing slides between tabs.
- Inside a window only what slides in the app slides: the sidebar, and a
  column that opens beside the terminal by itself (a tab opened there, as
  the ⌘-clicked page is: 500ms on `power3.inOut`). A split somebody makes, a
  tab dropped on an edge, a split that is closed, a zoom and a new
  arrangement land in one cut, with the same 200ms fade on what the cut
  brought. What slides clips its pane instead of reflowing it: the pane
  stays where it is at rest, held to the window's edge on its own side, and
  the divider passes over it.
- A dragged tab is drawn the way the app draws one (`BottomStrip.swift`, the
  tab drag's overlay): the tab's own picture under the pointer at 90%, the
  tab itself at 35% in its row, and where it would land at 10% of the
  accent with no words: all of a split over its middle, and over an edge the
  half a new split would take, with a 1px line at 55% on the side that meets
  the old one (`.carried`, `.landing` in `site.css`).
- Every hover sits behind `@media (hover: hover) and (pointer: fine)`, so a tap
  on a phone never leaves one stuck on.
- Nothing appears from `scale(0)`: from 0.5 or more, with opacity.
- Arriving on the page (`data-reveal`, `scripts/reveal.ts`) uses
  `--ease-settle`, a long soft landing: words rise 16px out of a 6px blur over
  900ms. A stage arrives in layers: the frame opens from a slightly smaller cut
  and rises 48px, the photo inside it settles from 112% to its crop over
  1.8s, and what stands on it (controls, then the window) rises 40px a beat
  later (+200ms, +320ms). The hero's stage does the same, so the first one
  matches the rest, but `scripts/hero.ts` picks the moment (`reveal="manual"`):
  the claim a line at a time, then the copy, then at 1s the lake opens and
  the window rises, and the typing starts at 3s, once it has settled.
- The photo is the stage's `::before`, apart from the frame, and drifts 80px
  over the time the stage takes to cross the screen (a scroll-driven
  animation, where the browser has them). It overhangs top and bottom by 40px,
  so no edge shows. The footer's fog rides on it through `--over`.
- Crossfades of icons (play/pause) carry a 4px blur, so the overlap reads as
  one thing changing.
- The chapter tabs are two copies of the labels: the lit copy (the black pill
  with white words) is clipped to the current tab and the clip slides, so a
  label turns white exactly where the pill is.
- Reduced motion keeps fades and drops movement.

### 1:1 with the canvas

- A window's edge is drawn once, in `.stage .win` (styles/site.css): one
  rounded clip, one hairline just inside it as a real 0.5px border (snapped to
  device pixels, unlike a 0.5px box-shadow), and the canvas's drop shadow
  without its near-black ring, which was drawn for a black artboard. The
  canvas's own shadow and Rim are switched off inside it, so nothing is drawn
  twice. `components/Window.astro` is the canvas's Window otherwise: glass,
  then the layout row, at the canvas's sizes (sidebar 234, column 384).
- Claude Code sessions look the way Claude Code 2.1 draws them (captured from
  a real session in a 60x34 pty): the header with the mascot, version, model
  and folder at the top; the prompt box and mode line pinned to the bottom; the
  status line one row above them while it works, with "esc to interrupt" on
  the mode line. `app.ts` adds the header (`claudeHeader`) and the status
  (`term.status()` / `term.idle()`); `app.css` pins the box. The canvas drew
  the older layout, where the box follows the last line.
- `wholeRows()` hides terminal and sidebar rows that do not fit, so a window
  never shows half a row. Call it on any window whose height is not the
  canvas's. A terminal makes room by scrolling its box to a row's edge, with
  the rows above left in place and unseen, never by taking them out: rows
  taken out move every row under them, which Chrome counts as layout shift,
  and a film printing a line a second put the homepage's score on a phone at
  0.108 (0.1 is the limit for "good"). Scrolled, it measures 0. A terminal
  also fits itself again whenever what it holds changes, so a scene need not
  ask. A sidebar is cut from the end but keeps the selected row and its
  header (the sessions in no folder come last, so the one a window shows is
  often there), and its section gaps are worked out again for what is left.
- Traffic lights are drawn in CSS as true 14pt circles in the captures'
  colours, so they are crisp at 1x, 2x and 3x.
- The window's corner, Running and "…", is the window's own layer over the
  titlebar, 8 from its right edge, whatever the splits under it do.
  `components/Window.astro` puts the canvas's `Window controls` there in
  every window it draws (the hero's window is one frame and brings its own).
  A pane on the canvas ends its row 8 from its edge, and the rightmost row
  along the top has to end 72 from the window's, which leaves 4 between Split
  Down and Running. So the slot that holds that row carries `data-end`
  (`site.css`: `.win [data-end] header`). In the splits film the mark moves
  with the splits (`lay()` in `scripts/panes.ts`), and when a column slides
  in at the outer edge the row that was the rightmost gives the 72 back on
  the slide's own curve. On a phone,
  where a folded window's main row is the only one, the stylesheet gives it
  the 72.
- A split's row of tabs is fitted to its width the way the app fits one, so
  a pane drawn at 384 is right at 234 or at a phone's width (`fitBars()` in
  `scripts/app.ts`, which `wholeRows()` calls; the styles are in `site.css`).
  The split buttons show while the row has 240 points of its own. Tabs that
  do not fit give up the room for their close buttons, then give way
  together to 130 points with their titles cut, then the row scrolls to the
  tab in front under a 20px fade with the "+" still after it, as the
  canvas's own History state draws a row that ran short. A zoomed split's
  row keeps Show All Splits when its two split buttons go, as the app's
  does.
- A plain shell on the canvas (the strip, the terminal in a split) ends in a
  spacer that keeps its lines at the top. `app.css` takes that spacer out of
  every terminal for Claude's pinned prompt box, so the splits film says it
  again for the shell in its split (`Panes.astro`).
- The splits film composes what the canvas draws as whole states ("Splits",
  "Zoomed split") out of three panes, and these things in it are the site's:
  - The agent's terminal is "Terminal, a note pasted" (`NotePasted.astro`),
    drawn for the mark-up film, with its prompt emptied: nothing has been
    pasted yet. Zoomed, its row gets the canvas's Show All Splits, cloned
    from the dev server split's row, where the canvas drew it.
  - The shell beside it is the canvas's zoomed dev server split
    (`ZoomedSplit.astro`). The film starts it as a new shell: the canvas's
    own lines are hidden and shown as they would have arrived, with a login
    line before them, and the tab is named for the folder, then for what
    runs in it. Its own Show All Splits never shows.
  - The browser is "Mark-up, a page" (`MarkUpPage.astro`), for its capture
    of the landing page at a split's width in both colour schemes. Its
    mark-up layers and the header hairline that comes with them are hidden,
    the page is as wide as its split and cut off at the bottom, and only the
    capture the colour scheme shows is fetched (`schemePictures()`). It is
    one pane, moved from the column at the edge to the split under the
    shell when its tab is dropped there.
  - A row lower down has the band look, where the browser's was drawn with
    the titlebar's: 36 high, the strip's wash on the page colour, no
    hairline, the front tab on the card colour (`Panes.astro`).
  - With three splits on screen, the front tab of each split the keyboard
    is not in keeps its fill and draws its glyph and title a step quieter
    (`data-quiet`, `site.css`), as the app does.
  - The column at the edge opens at the app's width, 440 and no more than
    half of what is beside the sidebar, which leaves the two terminals a
    quarter each until the tab is dragged away. That is what the app does.
- To check a window against the canvas: `opmaak render "<frame>" --scale 1`,
  screenshot the same markup at 1510x1015, and `magick compare`. Text will
  differ (the canvas renders with its server's fonts); boxes should not.

`/?t=<s>` holds the landing sequence at a time, for screenshots. Reduced
motion starts every film paused, on its most telling chapter.

**The windows on a phone** (760px and under). A window there is a small one,
not a cropped or a scaled one: as wide as the stage, at most 512px high, with
its sidebar folded, so the terminal wraps to the width and what the agent
says can be read. `foldable()` in `scripts/app.ts` gives such a window what
the app gives it in that state (the traffic lights on the window, Show
Sidebar in the main bar) and `site.css` shows them only at that width; a
`Stage` asks for it with `fold`, and the window carries `data-narrow` in its
markup, so the sidebar is folded from the first paint and nothing shifts
when the script runs. The split buttons are gone from that row, as they are
from any row in the app with under 240 points of its own. Three liberties are
taken for the session's name, which with no sidebar is on its tab and nowhere
else: Back and Forward are left out of the row, the hero's session shows one
tab of its three, and the row goes without its "+" (under 360px wide, without
Show Sidebar too). A fourth is the Settings window, which takes the stage's
width (it is 380 points in the app, wider than the stage) with its tabs moved
clear of the traffic lights.

Two films are about more than one part of the window, and a phone shows one
part at a time. Their windows are wider than the stage and the film pans:
the splits film between the agent's column (its split, and the shell under
it) and, while the browser is there, the column at the edge, each exactly as
wide as the stage, to whichever has the keyboard. What is off the stage is not
drawn, so no strip of the split next door shows in the stage's own margin.
So in "Drag a tab" the film goes to the page, and back with the tab as it is
carried, to where it lands; and a zoomed split
is the whole window, at the stage's width, with Show Sidebar and the "+"
left out of its row so the session's name and Show All Splits have the
room. The agents film pans between
the sidebar, while the dots are the story, and the terminal, once you have
gone to the session that asked. The pan is the camera's; nothing in the window moves
that the app would not move.

Between a phone and a wide screen (1000px and under: a tablet, a narrow
browser window) the splits window is whole but folds its sidebar, since
sidebar, terminal and column do not fit across and the terminal was left a
strip ten characters wide.

Every Download button on the site leads to `/download` with a mark for where
it was (`/download#hero`, `#nav`, `#footer`, `#404`). Arriving with one
presses the page's own button, so the download starts at once and
`download_clicked` carries that place; the mark is then taken out of the
address, so a reload does not download again. A plain visit to `/download`
only shows the button. On a phone or a tablet nothing starts by itself: the
button becomes "Send to your Mac" (the share sheet, or "Copy the link" where
there is none, `download_link_sent`), and the download is a small link under
it (`download_clicked` from `download-phone`). The page tells such a device by
what it is, not by its width, since the question is whether it can open a Mac
app. The button points at `https://updates.wortel.sh/Wortel-latest.dmg`,
which `release.sh --publish` always mirrors to the newest notarized build: a
plain disk image with the app beside a link to Applications
(`macos/scripts/make-dmg.sh`). Sparkle keeps its zips; the DMG is only the
website's. Until the bucket has a DMG, the build links the zip and its steps
instead (`src/data/site.ts`), so a deploy can't put a 404 behind the button.
The version line under the button and `softwareVersion` in the
structured data are read from `updates.wortel.sh/appcast.xml`, and the size
(`fileSize`) from a HEAD of the DMG, both **at build time**. They refresh on
redeploy, not on their own.

## The letter

An email when something big ships, a few times a year, to the people who ask
for it. For now the site only collects: how letters are sent is decided when
there is one to send (`docs/decisions.md`, 2026-11-26). What is kept is on
`/privacy`, and changes there before it changes here.

```
worker/letter.ts           the decisions: what an address is, the form, the token, the mail
worker/letter-routes.ts    POST /letter/join, GET+POST /letter/confirm and /letter/leave, the sweep
worker/letter*.test.ts     `npm test` (letter-routes.test.ts on node:sqlite with the real schema)
migrations/                the D1 schema (database `wortel-letter`, EU jurisdiction)
components/LetterForm.astro  the form: a real POST, sent in place with JS
pages/letter.astro, pages/letter/[state].astro   /letter and the pages the requests end on
```

The words are `LETTER` in `src/data/site.ts`. The confirm and leave links
open a page with a button rather than doing the thing, because mail scanners
open every link. Those two pages carry no analytics: their address holds the
token.

**Setup, once** (an account change, so only when asked): the Workers Paid
plan, `npx wrangler email sending enable wortel.sh`, then
`npx wrangler d1 create wortel-letter --jurisdiction eu`, its id into
`wrangler.jsonc`, and `npx wrangler d1 migrations apply wortel-letter --remote`.
The database was created and migrated on 2026-11-27. Email Sending for
wortel.sh was not enabled then: until it is, a site deploy puts up a form
whose confirmation mail fails. The form still says "check your inbox" (a join
answers before its mail is sent, so the answer cannot tell anyone who is on
the list), no mail comes, and the log says `letter: confirmation mail failed`.

**Try it locally:**

```sh
npx wrangler d1 migrations apply wortel-letter --local
npm run build && npx wrangler dev --local
```

Addresses not confirmed within a week are deleted once a day by the cron in
`wrangler.jsonc`, and on every join. To run the sweep by hand under `wrangler
dev`: `curl "localhost:8787/cdn-cgi/handler/scheduled?cron=17+3+*+*+*"`.

The confirmation mail is not sent from `wrangler dev`: it is written under
`.wrangler/tmp/email/` and the path is printed in the log. Its link says
`https://wortel.sh`, because `wrangler dev` hands the Worker the route's host:
open it with `localhost:8787` in its place.

**The list:**

```sh
npx wrangler d1 execute wortel-letter --remote --json \
  --command "select email, token from subscribers where confirmed_at is not null"
```

A letter that goes out must link to `https://wortel.sh/letter/leave?t=<token>`
for each address, and should send `List-Unsubscribe` with that address and
`List-Unsubscribe-Post: List-Unsubscribe=One-Click`, which the same route
answers.

## The app window, in two looks

The window on the page is a pixel replica of the real app, and the real app is
native, so it changed appearance when macOS did. Both looks ship:

```
demo/App.svelte            picks one; everything mounts THIS, never a look
demo/look.svelte.js        which macOS the visitor is on
demo/tokens.css            macOS 26 palette      demo/tokens27.css        macOS 27
demo/WortelApp.svelte      macOS 26 window       demo/WortelApp27.svelte
demo/Sidebar.svelte        macOS 26 sidebar      demo/Sidebar27.svelte
demo/GitPanel.svelte       macOS 26 inspector    demo/GitPanel27.svelte
demo/Terminal.svelte  demo/Diff.svelte  demo/data.js  demo/drawer.svelte.js
                           shared by both: content and behaviour, not chrome
```

Both edge panels are draggable by a grip on their inner edge, like the three
real split panes in the app: the sidebar clamps to 180…400 and the inspector to
220…70%, the same thicknesses `MainSplitViewController.swift` sets. The width
lives in `--w-sb-w` / `--git-w`, and the toggle, the window title and the
terminal's padding all read it, so they travel with the edge instead of with a
literal.

macOS 27 is the default, and what the built HTML carries. Browsers do not
volunteer the OS version, so `look.svelte.js` asks User-Agent Client Hints
(Chromium, the only one that answers), falls back to Safari's own version as a
proxy, and leaves everyone else on the new look. A visitor it places on macOS
26 is swapped once, right after hydration.

**Pixel work is measured, never eyeballed.** Put 2x screenshots of the real
window in `public/refs/` as `m27-{light,dark}-{history,changes,files}.png`, then
open `/pixel?ref=history&theme=light&mode=onion` (also `diff`, `app`, `ref`,
and `look=26`) to overlay the live window on one at 1:1. Both the refs and that
page are gitignored, AND `npm run build` deletes them out of `dist/`: they are
local tools, 7MB of screenshots has no business on wortel.sh, and a release is
allowed to deploy the site by itself (`scripts/release.sh --publish` rebuilds
it so the version number refreshes). Nothing about keeping them out may depend
on whoever runs that remembering to.

Screenshots off a Mac are **Display P3**. Sampling one raw and pasting the
number into CSS (which is sRGB) shifts every saturated colour: it is what first
made macOS 27 look like it had muted the traffic lights. Convert first.

```sh
magick public/refs/m27-light-history.png \
  -profile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" out.png
```

Headless Chrome renders the harness at exactly the refs' size, which is what
makes a numeric diff possible:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --force-device-scale-factor=2 --window-size=1416,919 \
  --virtual-time-budget=6000 --screenshot=out.png \
  "http://localhost:4321/pixel?ref=history&theme=light&mode=app"
```

## /compare

`src/data/compare.ts` holds the lot: the apps, the ten questions, and every
cell. Two rules keep the page honest and are worth keeping.

**Every claim is read off that product's own site, docs or repository**, never
off a competitor's comparison page. The header of the module lists what each
column was checked against.

**`unknown` is a real answer.** Where a product does not publish something the
cell renders as "?" and reads "not published". It is not a polite "no", and
rounding it down to one is how you end up wrong in public about someone else's
software.

The grid shows Wortel and three others, each chosen from a menu, because
there is no width that shows ten columns of sentences. On a phone (760px and
under) it shows Wortel and one other, with each question on a line of its own
over the two answers and the two names staying in view under the nav. Without
scripts every column is there and the grid scrolls sideways in its own box. Nothing inside the panels draws
a rule: the page is graph paper, and a hairline on graph paper is just another
grid line at the wrong offset.

**Heads up when you switch to a branch that has this page.** `/compare` used to
be the local pixel harness, so a checkout made before this page existed may
still have an untracked `src/pages/compare.astro` sitting where the tracked one
wants to go, and git will abort rather than clobber it.

Only do this on a checkout that has the OLD harness. Run it inside a checkout
that already has this page and you will rename the page itself into a gitignored
file and lose the route. The guard checks which one you have, so it is safe
either way:

```sh
# renames ONLY if the file is untracked, i.e. it is the old harness
git ls-files --error-unmatch web/src/pages/compare.astro >/dev/null 2>&1 \
  || mv web/src/pages/compare.astro web/src/pages/pixel.astro
```

## Content & SEO

The page is two things stacked: a fixed 100vh hero (the pixel-measured grid
layout plus the Svelte app replica) and, below it, an ordinary scrolling
document. Nothing in the hero may change length: the whole thing is snapped to
a 36px grid, and the app window's anchor is derived from it.

**No em dashes anywhere in copy.** Use a colon, a full stop, a semicolon or
parentheses. The rule covers every string in `src/data/site.ts`, the templates,
and any HTML comment that ships in the build (`is:inline` script comments and
`<!-- -->` blocks are served verbatim, so they count). Check with:

```sh
npm run build && grep -rl '—' dist/ ; echo "exit 1 above = clean"
```

**Edit copy in `src/data/site.ts`, never in the templates.** The page, `/docs`,
the JSON-LD (`SoftwareApplication` + `FAQPage` + `TechArticle`), `/llms.txt` and
`/llms-full.txt` all render from that one module, so they cannot drift apart. An
answer a model quotes out of `llms-full.txt` is the same sentence a visitor
reads.

### The homepage is the pitch; /docs is the manual

`SECTIONS` is what someone deciding whether to download this needs, and nothing
else. `DOCS_SECTIONS` is the reference: the `wortel` command table, the
shortcuts, and the second and third pass at how a mechanism works. **When a
paragraph starts explaining HOW rather than what it does for you, move it.**

The landing page was 2,456 words and thirteen screens, and about half of that
was reference material sitting below everything else. Nothing was deleted; it
moved to a page that is linked, in the sitemap, in `llms.txt`, flattened into
`llms-full.txt`, and can be landed on directly by a search for "wortel keyboard
shortcuts", which a `#keyboard` anchor never really allowed.

The FAQ stayed, as `<details>` rows in the right column of its section. Sixteen answers written to stand alone are
the most quotable thing here and the source of the `FAQPage` node, so collapsing
beats cutting: the text is in the HTML whether or not a row is open, so crawlers
and screen readers still get every word, and it needs no JavaScript. They carry
no `name` attribute on purpose, so more than one can be open at a time.

## Adding a release to the changelog

Write one Markdown file, named for the version:

```sh
$EDITOR src/content/releases/2026.33.1.md
```

```markdown
---
date: 2026-08-14
title: What this release is about
summary: One line. It leads the in-app update dialog.
---

A short paragraph if the release deserves one, then bullets.

- What changed, in the same voice as the rest of the site.
```

That is the whole procedure. **The filename is the version** and the only place
it is written down, so a note cannot disagree with itself; `date`, `title` and
`summary` are schema-checked at build time, so a malformed entry fails the build
rather than shipping. Two things render from the file:

- **`/updates`**, the changelog, newest first, sorted by version rather than by
  date (three releases shipped on 2026-07-30).
- **`/release-notes/<version>.html`**, a standalone fragment.
  `macos/scripts/release.sh --publish` copies it next to the archive as
  `Wortel-<version>.html`, where `generate_appcast` embeds it as CDATA. That is
  the text Sparkle shows in the **in-app update dialog**, and embedding means it
  renders with no network fetch.

Publishing without a note is refused (`--no-notes` overrides), and the check runs
before anything is built or uploaded.

Regenerating the images (needs ImageMagick + librsvg):

The 2784x1824 masters live in `art/`, NOT in `public/`: they are build inputs,
and while they sat in `public/` they were published too, which was 4.2MB of the
5.2MB deploy for two files nothing ever referenced.

```sh
# The app screenshot, from the masters in art/. NOT embedded in the page: it is
# what SoftwareApplication.screenshot points at in the structured data.
#
# It was put on the page once, at the top of "At a glance", to give the site a
# raster image (the window up top is a Svelte replica, so image search has
# nothing to find). It came back off: the masters catch the app mid-
# conversation, and at 900px from a 1392px source the text stops being readable
# and turns into texture. A shot composed for the purpose would be worth
# another go, and light/dark webp variants beside it, but a bad one is worse
# than none.
#
# -profile BEFORE -strip, and that order is the whole trick. The masters carry
# an Apple "Color LCD" display profile, so stripping first threw the profile
# away without converting anything and left every saturated pixel to be read as
# sRGB: the same Display P3 mistake the refs section above warns about, which
# had been baked into the shipped screenshot.png.
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
magick art/app-shot-dark.png -profile "$SRGB" -resize 1392x912 -strip public/screenshot.png
# icons
# exported from the app's own Icon Composer file, so the site never drifts from it
ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" ../macos/Wortel/AppIcon.icon --export-image --output-file /tmp/icon.png --platform macOS --rendition Default --width 512 --height 512 --scale 2
for n in 512 256 180 128 96 32; do sips -z $n $n /tmp/icon.png --out public/icon-$n.png; done
mv public/icon-180.png public/apple-touch-icon.png; mv public/icon-96.png public/favicon-96.png; mv public/icon-32.png public/favicon-32.png
# /favicon.ico: no page links it, but Bing and many tools ask for it by name
magick public/icon-256.png -define icon:auto-resize=48,32,16 public/favicon.ico
```

`public/og.png` (1200x630) is composed from the grid background, the cropped app
window and a text layer. See the git history for the exact commands. It is the
homepage's card, and the fallback for any page that names none.

The inner pages each have their own card in `public/og/<page>.png`, passed to
`Layout` as `ogImage`. They are rendered by the Chrome already on the Mac, with
no dependency, and committed:

```sh
node scripts/og/render.mjs          # all of them
node scripts/og/render.mjs docs     # one
```

The copy for each card is in that script. Keep it to things that stay true (no
version numbers, no release counts): social networks cache a card for days.

### Markdown for agents

Besides `/llms.txt` and `/llms-full.txt`, the main pages exist as Markdown at
the same path plus `.md`: `/index.md`, `/docs.md`, `/compare.md`,
`/mark-up.md`, `/layouts.md`, `/updates.md`. Each page's `<head>` points at its own with
`rel="alternate" type="text/markdown"` (the `markdown` prop on `Layout`). All of
them, and `llms-full.txt`, render from `src/data/markdown.ts`.

### Not found, and www

`src/pages/404.astro` builds `dist/404.html`, which `not_found_handling:
"404-page"` in `wrangler.jsonc` serves with a 404 status for any path that
matches no file. It is `noindex` with no canonical. A miss, a browser's
navigation included, reaches the Worker first and is handed back for this page
(the `assets_navigation_has_no_effect` flag in `wrangler.jsonc`, without which
the letter's links never reached the Worker). The page drops its own query
before analytics starts, so a mangled letter link's token is not reported.

`www.wortel.sh` is not served by this Worker. It is a proxied placeholder DNS
record plus a zone Redirect Rule (dashboard: Rules, Redirect Rules) that 301s
to `https://wortel.sh` with the path and query kept, so there is one copy of
every page.

`public/robots.txt` is ours and **replaces Cloudflare's managed one**, which was
the Content Signals boilerplate with no directives. It allows everything,
carries a permissive `Content-Signal:` line, and points at the sitemap.

### One URL per page, without a slash

Canonical tags and sitemap entries are both built from a path like `/compare`,
with no trailing slash. Astro builds `/compare/index.html`, and Cloudflare's
default (`auto-trailing-slash`) serves that at `/compare/` while redirecting
`/compare` to it, so **every subpage was canonicalising itself to a redirect**
and the sitemap was a list of 307s. `html_handling: "drop-trailing-slash"` in
`wrangler.jsonc` serves the no-slash form instead. The three have to agree;
changing any one of them alone reintroduces the mismatch.

```sh
npm run cf-preview   # then: /compare is 200, /compare/ is a 307 back to it
```

### lastmod is a date, not a build stamp

`sitemap.xml.ts` asks git when each page's **content sources** last changed, not
when the site was last built. `/updates` uses the newest release's frontmatter
date and the legal pages use their own `updated` field, so neither needs git at
all. This matters because `release.sh --publish` redeploys the whole site: a
build-stamped `lastmod` told crawlers all five URLs changed every time one
Markdown file shipped, which is how a site teaches Google to ignore the field.
Uncommitted edits do not count, deliberately. No git in the environment falls
back to the build date rather than failing the build.

## Photos

Every stage stands on one of four photos from Unsplash (free to use under
the Unsplash License, credit optional). `<Stage photo="…">` picks one, and
`at`/`zoom` the part of it; neighbouring sections never share a photo.
The closing call (components/Footer.astro) picks a photo per page, with a
crop that keeps fog behind the words.

A crop is written in one place, `data/photo.ts`: `at` is a
background-position and `zoom` a number, where 1 fills the stage and 2 is
twice the stage's width. The photo always covers its stage. A zoom makes the
photo's layer wider and the photo covers that layer (`.stage::before` in
`site.css`), so on a phone, where a stage is taller than it is wide, the photo
grows to the stage's height. Do not size a photo with a width alone
(`background-size: 200%`): that left a bare band under the picture on phones.
The three photo tiles in the bento crop the same way.

Each photo also has a phone copy, `<name>-1600.webp`, which a stage uses on a
screen up to 900px wide (`--photo-s` in `site.css`). Make one with
`cwebp -q 78 -m 6 -resize 1600 0 <name>.jpg -o <name>-1600.webp`. Only the
hero's photo is fetched with the page (it is preloaded in `pages/index.astro`);
every other stage asks for its photo when it comes within a screen and a half
(`data-photo`, `scripts/reveal.ts`).

| File | Where | Source |
|---|---|---|
| `lake.jpg` | Hero, the homepage's closing call | the "Foggy Lake" shot on the Opmaak canvas, found on Unsplash |
| `skye.jpg` | Panes, three bento tiles (each its own crop), /download, the closing call on /updates | https://unsplash.com/photos/LGOX15iP0u0 |
| `haze.jpg` | Agents, the closing call on /docs and /about | https://unsplash.com/photos/dDKjrFzijbM |
| `hills.jpg` | Start (a terminal first) and the closing call on /compare (cropped to the forest and fog; the flower at the bottom stays out) | https://unsplash.com/photos/Mg1AQZnCgJE |

The three newer ones were picked for colour: the closest of ~30 misty-lake
photos to the lake by their Lab distribution. Saved at 2400px, quality 76,
with a light blur on hills and haze to settle the film grain.
