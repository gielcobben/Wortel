# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this
repository.

## Monorepo layout

This repo holds everything for **Wortel** — a minimal, performance-first, fully
native macOS terminal built on libghostty.

> **Naming:** "wortel" is Dutch for **root** (as in the root of a plant / the
> root shell) — that's the intended metaphor, not "carrot". The site's copy
> is built on it, and its look is a foggy lake. The mark is the app icon in
> `macos/Wortel/AppIcon.icon`: the site's icons are exported from it, never redrawn.

```
macos/    The macOS app. Swift + XcodeGen. Ships to updates.wortel.sh via
          Sparkle (R2). This is the product. See macos/CLAUDE.md.
web/      The landing page → wortel.sh. Astro static site deployed to
          Cloudflare Workers static assets. See web/README.md.
updates/  The Worker serving updates.wortel.sh: the appcast and the signed
          zips out of R2, and the only place downloads are counted. See
          updates/README.md.
```

`updates/` is its own deployable rather than part of `web/` on purpose. The
update channel must not be able to go down with a bad landing-page build, and
`release.sh --publish` redeploys the landing page at the end of every release.
This one changes almost never.

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

# updates worker
cd updates && npm install && npm test      # pure classification tests, no network
cd updates && npm run deploy               # wrangler deploy to updates.wortel.sh
```

## Writing: no em-dashes in anything a user reads

**Never use an em-dash (or an en-dash as punctuation) in copy a user reads.**
Rewrite with a comma, a colon, brackets, or two sentences. This covers UI
strings, release notes, the website, and the on-device model prompts in
`SessionNameGenerator` / `CommitMessageGenerator`, which must also *forbid* the
dash in what they generate: a commit message is copy too, and those prompts are
told to match the style of recent subjects, which are full of them.

An em-dash reads as machine-written, and the writing everywhere in this repo is
deliberate enough that the tell stands out.

**Source comments, design docs and commit messages are exempt** and are full of
them. They are for whoever is reading the source, which is a different audience.
Don't sweep those, and don't rewrite changelog entries that already shipped.

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
