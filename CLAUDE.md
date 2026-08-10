# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this
repository.

## Monorepo layout

This repo holds everything for **Wortel** — a minimal, performance-first, fully
native macOS terminal built on libghostty.

> **Naming:** "wortel" is Dutch for **root** (as in the root of a plant / the
> root shell) — that's the intended metaphor, not "carrot". Some current landing
> assets (favicon, copy) lean on the carrot reading; those are placeholders to be
> reworked around the root theme.

```
macos/   The macOS app. Swift + XcodeGen. Ships to updates.wortel.sh via
         Sparkle (R2). This is the product. See macos/CLAUDE.md.
web/     The landing page → wortel.sh. Astro static site deployed to
         Cloudflare Workers static assets. See web/README.md.
```

Each app is self-contained: its build tooling, scripts, and dependencies live
under its own directory. There is no shared build system or workspace manager —
`macos/` is an Xcode project, `web/` is an npm/Astro project. Work in one rarely
touches the other.

**Read the app-local doc before working in an app:**
- `macos/CLAUDE.md` — architecture, build/run, release, conventions.
- `web/README.md` — dev, build, deploy for the landing page.

## Quick commands

```sh
# macOS app
cd macos && xcodegen generate && \
  xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build

# landing page
cd web && npm install && npm run dev      # local dev
cd web && npm run deploy                   # build + wrangler deploy to wortel.sh
```

## Distribution & Cloudflare

Both apps share one Cloudflare account and the `wortel.sh` zone:
- **updates.wortel.sh** — R2 bucket `wortel-updates`, the Sparkle appcast +
  signed app zips (published by `macos/scripts/release.sh --publish`).
- **wortel.sh** — the `wortel-web` Worker serving `web/dist` (deployed by
  `web/` → `npm run deploy`).

### The changelog

One Markdown file per release in `web/src/content/releases/`, **named for the
version** (`2026.32.2.md`). It is the only place release notes are written, and
it feeds both the public changelog at `wortel.sh/updates` and the notes Sparkle
embeds in the in-app update dialog. `release.sh --publish` refuses to publish a
version with no note. See `web/README.md`.
