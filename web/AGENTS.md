# web/: wortel.sh

For coding agents working on the landing page. The repo-wide rules in the root
`AGENTS.md` still apply. Paths and commands here are relative to `web/`.

An Astro site, fully static, served by a Cloudflare Worker as static assets.
`README.md` is the long form: structure, motion, the canvas, SEO, photos. Where
it and this file disagree about layout, this file and the header of
`src/styles/site.css` are current.

## Commands

```sh
npm install
npm run dev          # http://localhost:4340
npm run check        # typecheck the pages and the worker
npm run build        # → dist/, with the local pixel tools stripped out
../scripts/check.sh web   # check + build + the em-dash check on the built site
```

`npm run deploy` publishes to wortel.sh. Only when asked.

## Before you add or change anything

1. Read the header comment of `src/styles/site.css`. It is the design system,
   and it is short.
2. Read `../DESIGN.md` for the numbers (the site's, and the app's that the
   windows are drawn with), `../docs/brand.md` for the look and
   `../docs/voice.md` for the words.

## Rules

**Layout**

- One container. Headings and visuals start at its left edge; what there is
  to read about a heading starts beside it. Nothing is centred.
- Every section on every page opens with the same row, `.row12`: a hairline,
  its name at the left, the text at the right. On the homepage that is
  `components/Section.astro`: the name in columns 1 to 5, a short paragraph in
  7 to 12, and the stage or the bento under the row at full width.
- An inner page is `.phead`, then `.row12.read` rows: the name smaller, in
  columns 1 to 3, and the text in 4 to 11. A page of text never goes in the
  homepage's narrow right half. That was tried and read as a sidebar.
- Headings are light (weight 400, the page's one large line 500) and short: the
  claim in ink, its other half in grey on the line under it. Never one long
  line, no full stop, and nothing in a heading changes while a film plays.
- No mono numerals, bracketed links or margin indexes as decoration. Mono is
  for code and keys.
- Every margin, padding, gap and fixed height is a multiple of 8. No 4, 10, 12,
  14 or 20. When text sets a row's height, give it a line-height on the grid.
  Hairlines, radii, font sizes and measured widths are exempt.
- Don't name a site class after a Tailwind utility (`block`, `grid`, `flex`).
  The generated app markup uses those.

**Copy**

- All standing copy is in `src/data/site.ts` (and `src/data/compare.ts` for
  `/compare`). Never in a template. The homepage's headings and paragraphs are
  `HOME` there. The page, `/docs`, the structured data and
  the `llms` files render from it, so they cannot drift.
- Inside a sentence in `site.ts`, write what is typed, a path or a file name
  in backticks, and a key or chord the same way (`` `⌘N` ``). The page turns
  the first into code and the second into a key cap (`src/data/inline.ts`),
  and the Markdown files pass them through. `**bold**` works too. Anything
  that must be plain text, like the structured data, goes through `plain()`.
- A docs section that holds more than one subject gets a small heading
  between them (`{ h: '…' }`), not one long paragraph.
- The homepage is the pitch. `/docs` is the manual. A paragraph that explains
  how something works belongs on `/docs`.
- No em-dashes anywhere that ships, HTML comments included.
- On `/compare`, every claim is read off that product's own site, docs or
  repository, and "unknown" is a real answer.

**The app on the page**

- Every window is the real interface, generated from the design canvas into
  `src/app/gen/`. Never edit those files by hand. `scripts/opmaak/regen.sh`
  regenerates them, and `regen.sh --check` says whether they match the canvas.
  That script is maintainer-only (it needs the private `opmaak` CLI); a
  contributor doesn't need it, because `src/app/gen/` is committed.
- 1:1, never scaled. A shorter window is fine. Never half a row
  (`wholeRows()`).
- On a phone (760px and under) a window is as wide as the stage with its
  sidebar folded, and the terminal wraps. Give a new stage `fold`, its window `data-narrow`,
  and call `foldable()` on it (`src/scripts/app.ts`). A film about more than
  one part of the window gets a wider window and pans to the part instead,
  as `panes.ts` and the agents in `scenes.ts` do. A line a script prints
  must be able to wrap: no fixed height, no `whitespace-pre`.
- Change a window's state through `src/scripts/app.ts`, not by touching markup.
- It follows the page: light on the light page, dark at night. Check both.
- Icons are exported from `../macos/Wortel/AppIcon.icon`. Never redrawn.

**Search and language models**

- One `<h1>` a page. A piece of the app that shows a document goes inside
  `components/AppContent.astro`, which turns the document's headings into
  plain blocks.
- The app windows carry `data-nosnippet`: what they show is made-up work, and
  a search result must not quote it as the page's words.
- A new page needs a title under about 60 characters, a description of about
  150, a line in `src/pages/sitemap.xml.ts`, and a mention in
  `src/pages/llms.txt.ts`. Run the build and read its `<head>`.
- A claim on the page that is also in the structured data
  (`src/data/schema.ts`) changes in both.
- Only what is in the first screen is fetched with the page. A stage below it
  carries `data-photo` (the `Stage` component does this unless it is `eager`)
  and gets its photo when it nears; a picture inside an app window below the
  fold goes in `AppContent.astro`. A new photo needs its phone copy,
  `<name>-1600.webp` (`README.md`, Photos).

**On a phone**

- No page scrolls sideways. A table of terms stacks (`table.terms`), a wide
  grid finds another shape (`/compare` shows two columns there), and anything
  that must stay wide scrolls inside its own box.
- Hover styles sit behind `(hover: hover) and (pointer: fine)`. A control
  under a finger takes taps from 40px or more: give a small one `.tap`
  (`site.css`, Touch) instead of drawing it larger.
- A Download button never hands a phone the download. `/download` offers to send
  the page to the Mac there.
- Check at 320, 390 and 430 wide, light and dark, before calling it done.

**Motion**

- The rules are in `README.md`, Motion and interaction. Use the three curves
  in `site.css`. No ease-in.
- Nothing is tied to scroll except the photos' small drift. No pinned
  sections, no scroll snapping. Both were built and removed.
- Reduced motion keeps fades and drops movement.

## Checking your work

- Look at it in a real render, in light and dark, at a phone width and a wide
  one. Then zoom in: corners, traffic lights, tab labels, the last row of a
  window. Details here are judged at pixel level.
- Use Playwright or headless Chrome. A tab that reports itself hidden never
  receives IntersectionObserver callbacks, so the films look stuck when they
  are not.
- `/?t=<seconds>` holds the landing sequence at a moment, for a screenshot.
- Sampling a colour from a Mac screenshot: convert it from Display P3 to sRGB
  first (`README.md` has the command), or every saturated value lands wrong.
- `public/refs/` is local and gitignored. The build deletes it from `dist/`.

## The changelog

One Markdown file per release in `src/content/releases/`, named for the
version. The `release-note` skill covers writing one. Notes that shipped are
not rewritten.

Each file is rendered as a page of its own at `/updates/<version>`, as a row
on `/updates` (the newest one in full, at the top), as an entry in
`/feed.xml`, and as the note in the app's update dialog.
`/updates#<version>` still works, because the app links that way: the newest
release is on that page and any other goes to its own.

A beta's note has `beta: true` in its frontmatter. It is on no list of
releases: every one reads the collection through `publicRelease`
(`src/content.config.ts`), and `src/data/release.ts` skips the appcast items
tagged with a channel. Its update-dialog fragment, `release-notes/<version>.html`,
is still built and deployed, unlinked, like every note's.
