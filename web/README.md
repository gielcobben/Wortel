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
  demo/                    the Svelte replica of the app window (see below)
public/                    static assets (favicon, og.png, screenshots, robots.txt)
```

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
open `/compare?ref=history&theme=light&mode=onion` (also `diff`, `app`, `ref`,
and `look=26`) to overlay the live window on one at 1:1. Both the refs and that
page are gitignored: local tools, and 7MB of screenshots has no business on
wortel.sh.

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
  "http://localhost:4321/compare?ref=history&theme=light&mode=app"
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

**Edit copy in `src/data/site.ts`, never in the templates.** The page, the
JSON-LD (`SoftwareApplication` + `FAQPage`), `/llms.txt` and `/llms-full.txt`
all render from that one module, so they cannot drift apart. An answer a model
quotes out of `llms-full.txt` is the same sentence a visitor reads.

Regenerating the images (needs ImageMagick + librsvg):

```sh
# the app screenshot, from the 2784x1824 app shots. Not embedded in the page:
# it is what SoftwareApplication.screenshot points at in the structured data.
magick public/app-shot-dark.png -resize 1392x912 -strip public/screenshot.png
# icons
rsvg-convert -w 180 -h 180 public/favicon.svg | magick - -background '#0e0f0d' -flatten public/apple-touch-icon.png
rsvg-convert -w 96  -h 96  public/favicon.svg -o public/favicon-96.png
```

`public/og.png` (1200x630) is composed from the grid background, the cropped app
window and a text layer. See the git history for the exact commands.

`public/robots.txt` is ours and **replaces Cloudflare's managed one**, which was
the Content Signals boilerplate with no directives. It allows everything,
carries a permissive `Content-Signal:` line, and points at the sitemap.
