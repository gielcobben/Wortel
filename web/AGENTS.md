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

- One container, one left edge. Everything starts at the container's left edge.
  Nothing is centred and nothing alternates sides.
- A homepage section is always the same parts: a two-tone heading, then a
  stage. An inner page is `.phead`, then `.row12` rows.
- Every margin, padding, gap and fixed height is a multiple of 8. No 4, 10, 12,
  14 or 20. When text sets a row's height, give it a line-height on the grid.
  Hairlines, radii, font sizes and measured widths are exempt.
- Don't name a site class after a Tailwind utility (`block`, `grid`, `flex`).
  The generated app markup uses those.

**Copy**

- All standing copy is in `src/data/site.ts` (and `src/data/compare.ts` for
  `/compare`). Never in a template. The page, `/docs`, the structured data and
  the `llms` files render from it, so they cannot drift.
- The homepage is the pitch. `/docs` is the manual. A paragraph that explains
  how something works belongs on `/docs`.
- No em-dashes anywhere that ships, HTML comments included.
- On `/compare`, every claim is read off that product's own site, docs or
  repository, and "unknown" is a real answer.

**The app on the page**

- Every window is the real interface, generated from the design canvas into
  `src/app/gen/`. Never edit those files by hand. `scripts/opmaak/regen.sh`
  regenerates them, and `regen.sh --check` says whether they match the canvas.
- 1:1, never scaled. A shorter window is fine. Never half a row
  (`wholeRows()`).
- Change a window's state through `src/scripts/app.ts`, not by touching markup.
- It follows the page: light on the light page, dark at night. Check both.
- Icons are exported from `../macos/Wortel/AppIcon.icon`. Never redrawn.

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
