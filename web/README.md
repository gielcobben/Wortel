# @wortel/web

The landing page for Wortel, served at **wortel.sh**.

Astro static site, deployed to **Cloudflare Workers static assets**. Fully
static (`output: 'static'`); no server runtime, no SSR.

## Develop

```sh
npm install
npm run dev        # http://localhost:4321
```

## Build & deploy

```sh
npm run build      # → dist/
npm run deploy     # astro build && wrangler deploy → wortel.sh
npm run cf-preview # build + `wrangler dev` (serve dist through the Worker locally)
```

Deploy config is in `wrangler.jsonc` (assets-only Worker, `name: wortel-web`,
custom domain `wortel.sh`). The account/zone is shared with the app's Sparkle
feed at `updates.wortel.sh`. See the repo root `CLAUDE.md`.

## Structure

```
src/
  data/site.ts             ALL page copy: the single source of truth
  pages/index.astro        the landing page + JSON-LD
  pages/llms.txt.ts        /llms.txt        short map for language models
  pages/llms-full.txt.ts   /llms-full.txt   the whole page as Markdown
  pages/sitemap.xml.ts     /sitemap.xml
  layouts/Layout.astro     html shell + meta/OG/canonical/icons
  styles/global.css        all styling (terminal-flavored dark theme)
public/                    static assets (favicon, og.png, screenshots, robots.txt)
```

The download button points at `https://updates.wortel.sh/Wortel-latest.zip`,
which `release.sh --publish` always mirrors to the newest signed build. The
version line under it, and `softwareVersion`/`fileSize` in the structured data,
are read from `updates.wortel.sh/appcast.xml` **at build time**. They refresh
on redeploy, not on their own.

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

**Edit copy in `src/data/site.ts`, never in the templates.** The page, the
JSON-LD (`SoftwareApplication` + `FAQPage`), `/llms.txt` and `/llms-full.txt`
all render from that one module, so they cannot drift apart. An answer a model
quotes out of `llms-full.txt` is the same sentence a visitor reads.

Regenerating the images (needs ImageMagick + librsvg):

```sh
# screenshots, from the 2784x1824 app shots
magick public/app-shot-dark.png  -resize 1392x912 -strip public/screenshot.png
magick public/app-shot-dark.png  -resize 1392x912 -strip -quality 55 public/screenshot-dark.avif
magick public/app-shot-light.png -resize 1392x912 -strip -quality 55 public/screenshot-light.avif
# icons
rsvg-convert -w 180 -h 180 public/favicon.svg | magick - -background '#0e0f0d' -flatten public/apple-touch-icon.png
rsvg-convert -w 96  -h 96  public/favicon.svg -o public/favicon-96.png
```

`public/og.png` (1200x630) is composed from the grid background, the cropped app
window and a text layer. See the git history for the exact commands.

`public/robots.txt` is ours and **replaces Cloudflare's managed one**, which was
the Content Signals boilerplate with no directives. It allows everything,
carries a permissive `Content-Signal:` line, and points at the sitemap.
