# @wortel/web

The landing page for Wortel — served at **wortel.sh**.

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
feed at `updates.wortel.sh` — see the repo root `CLAUDE.md`.

## Structure

```
src/
  pages/index.astro     the landing page
  layouts/Layout.astro  html shell + meta/OG tags
  styles/global.css     all styling (terminal-flavored dark theme)
public/                 static assets (favicon)
```

The download button points at `https://updates.wortel.sh/Wortel-latest.zip`,
which `release.sh --publish` always mirrors to the newest signed build.
