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

Deploy config is in `wrangler.jsonc` (assets-only Worker, `name: wortel-web`,
custom domain `wortel.sh`). The account/zone is shared with the app's Sparkle
feed at `updates.wortel.sh`. See the repo root `AGENTS.md`.

## Structure

```
src/
  data/site.ts             landing-page AND /docs copy: the single source
  data/compare.ts          ALL /compare copy: the apps, the questions, every cell
  data/release.ts          the newest release, read from the appcast at build time
  data/schema.ts           the homepage's JSON-LD
  content/releases/*.md    the changelog, one Markdown file per release
  content/legal/*.md       /privacy, /terms (the filename is the route)
  pages/index.astro        the homepage: sections in components/home/
  pages/about.astro        /about   the name, why it exists, a family tree, six beliefs
  pages/updates.astro      /updates the changelog
  pages/compare.astro      /compare Wortel against nine named apps
  pages/docs.astro         /docs    commands, shortcuts, behaviour
  pages/release-notes/     /release-notes/<version>.html  notes for Sparkle
  pages/llms*.txt.ts       maps for language models
  pages/*.md.ts            /index.md, /docs.md, /compare.md, /updates.md: pages as Markdown
  data/markdown.ts         the renderers behind those and llms-full.txt
  pages/404.astro          the not-found page (dist/404.html)
  components/home/         Hero, Panes, Agents, Worktrees, Survival, Glance (specs + FAQ)
  app/gen/*.astro          the app's panes, GENERATED from the Opmaak canvas
  components/Stage.astro   a scene: the heading (its grey half changes per chapter), then the lake
                           with the chapter tabs and play/pause over the window
  components/Window.astro  the window's chrome exactly as the canvas draws it: glass, layout, rim
  scripts/app.ts           tools for acting on a generated window: select a row, set a status, print a line
  scripts/film.ts          a film with chapters: autoplay, tabs, arrow keys, captions
  scripts/hero.ts          the landing sequence (one GSAP timeline)
  scripts/panes.ts         the panes scene: a state per place, a target layout per chapter
  scripts/scenes.ts        the agents, worktrees and survival scenes
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

Every page sits on one container with one left edge; nothing is centred. A
homepage scene is `.sec` > a `Stage`: the two-tone heading, whose black half is
the scene's claim and whose grey half is the current chapter's line, then the
stage, a part of the foggy lake with the chapter tabs and a round play/pause
button over the app window at its natural proportions. An inner page is `.phead` and
then `.row12` rows: a label in columns 1 to 3, content in 4 to 11. Don't name
a site class after a Tailwind utility (`block`, `grid`, `flex`…): the app's
generated markup uses those.

### Motion and interaction

Every stage below the hero is a film with chapters (`scripts/film.ts`). A
chapter is a function that puts a real window in that chapter's state from
wherever it was, written through `scripts/app.ts` (`sb.select(…)`,
`sb.status(…, 'attention')`, `term.print('Tool', '(npm run build)', 'Bash')`)
rather than by touching markup. Chapters play by themselves while the stage is
on screen; a tab, the arrow keys, the pause button, or anything pressed in the
window itself stops that, and play picks it up again. Nothing the films do is
tied to scroll; only the photos drift a little against it (below).

The windows answer to the pointer: sessions select, folders fold, the sidebar
and column buttons and the tabs work (panes), the notification and the
prompt's choices work (agents), the Dock icon quits and reopens (survival).
Anything pressable is marked `data-row`, `data-fold` or `data-press` and gets
the app's own hover from `styles/app.css`.

Rules for motion, so a new piece moves like the rest:
- Curves are `--ease-out` (anything answering the reader) and `--ease-in-out`
  (something on screen moving to a new place), both in `site.css`. No ease-in:
  it starts slow, which reads as lag. Exits are quicker than entrances.
- Answers to a click stay under 300ms (the chapter thumb is 300ms, a press
  160ms). Only the films and the landing sequence take longer.
- Tabs and columns inside a window swap at once, with a 200ms fade in, as the
  app does. Nothing slides between tabs.
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
- Crossfades of text or icons (the heading's grey line, play/pause) carry a
  4px blur, so the overlap reads as one thing changing.
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
  canvas's. A sidebar is cut from the end but keeps the selected row and its
  header (the sessions in no folder come last, so the one a window shows is
  often there), and its section gaps are worked out again for what is left.
- Traffic lights are drawn in CSS as true 14pt circles in the captures'
  colours, so they are crisp at 1x, 2x and 3x.
- Headings step in size with whole-pixel line-heights, so every window sits on
  a whole pixel.
- To check a window against the canvas: `opmaak render "<frame>" --scale 1`,
  screenshot the same markup at 1510x1015, and `magick compare`. Text will
  differ (the canvas renders with its server's fonts); boxes should not.

`/?t=<s>` holds the landing sequence at a time, for screenshots. Reduced
motion starts every film paused, on its most telling chapter.

The download button points at `https://updates.wortel.sh/Wortel-latest.zip`,
which `release.sh --publish` always mirrors to the newest signed build. The
version line under it, and `softwareVersion`/`fileSize` in the structured data,
are read from `updates.wortel.sh/appcast.xml` **at build time**. They refresh
on redeploy, not on their own.

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

The grid shows as many columns as the width allows (two on a phone, three from
1040px, four from 1280px) and every column is chosen from a menu, because there
is no width that shows ten columns of sentences. Nothing inside the panels draws
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

The FAQ stayed, as `<details>` rows. Sixteen answers written to stand alone are
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
for n in 512 180 128 96 32; do sips -z $n $n /tmp/icon.png --out public/icon-$n.png; done
mv public/icon-180.png public/apple-touch-icon.png; mv public/icon-96.png public/favicon-96.png; mv public/icon-32.png public/favicon-32.png
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
`/updates.md`. Each page's `<head>` points at its own with
`rel="alternate" type="text/markdown"` (the `markdown` prop on `Layout`). All of
them, and `llms-full.txt`, render from `src/data/markdown.ts`.

### Not found, and www

`src/pages/404.astro` builds `dist/404.html`, which `not_found_handling:
"404-page"` in `wrangler.jsonc` serves with a 404 status for any path that
matches no file. It is `noindex` with no canonical.

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

| File | Where | Source |
|---|---|---|
| `lake.jpg` | Hero, Worktrees, the homepage's closing call | the "Foggy Lake" shot on the Opmaak canvas, found on Unsplash |
| `skye.jpg` | Panes, /download, the closing call on /updates | https://unsplash.com/photos/LGOX15iP0u0 |
| `haze.jpg` | Agents, the closing call on /docs and /about | https://unsplash.com/photos/dDKjrFzijbM |
| `hills.jpg` | Survival and the closing call on /compare (cropped to the forest and fog; the flower at the bottom stays out) | https://unsplash.com/photos/Mg1AQZnCgJE |

The three newer ones were picked for colour: the closest of ~30 misty-lake
photos to the lake by their Lab distribution. Saved at 2400px, quality 76,
with a light blur on hills and haze to settle the film grain.
