# AGENTS.md

Instructions for coding agents working in this repository. `CLAUDE.md` imports
this file, so every agent reads the same words.

## What this is

This repo holds everything for **Wortel**: a minimal, performance-first, fully
native macOS terminal built on libghostty, made for working next to coding
agents.

> **Naming:** "wortel" is Dutch for **root** (as in the root of a plant / the
> root shell). That is the intended metaphor, not "carrot". The site's copy
> is built on it, and its look is a foggy lake. The mark is the app icon in
> `macos/Wortel/AppIcon.icon`: the site's icons are exported from it, never redrawn.
> A beta build wears `macos/Wortel/AppIconBeta.icon` instead.

```
macos/    The macOS app. Swift + XcodeGen. Ships to updates.wortel.sh via
          Sparkle (R2). This is the product.
web/      The landing page → wortel.sh. Astro static site deployed to
          Cloudflare Workers static assets.
updates/  The Worker serving updates.wortel.sh: the appcast, the signed
          zips and the DMGs out of R2, and the only place downloads are
          counted.
docs/     What is true across all three: product, brand, voice, decisions.
```

Each app is self-contained: its build tooling, scripts, and dependencies live
under its own directory. There is no shared build system or workspace manager.
Work in one rarely touches another.

`updates/` is its own deployable rather than part of `web/` on purpose. The
update channel must not be able to go down with a bad landing-page build, and
`release.sh --publish` redeploys the landing page at the end of every release.

## Read first

Each app has its own `AGENTS.md`, loaded when you work there. Beyond that, read
what the task needs and no more:

| When you are about to | Read |
| --- | --- |
| Work in an app | `macos/AGENTS.md`, `web/AGENTS.md`, `updates/AGENTS.md` |
| Propose or build a feature | `docs/product.md` |
| Change how something works | `docs/decisions.md`: it may have been tried |
| Touch the keeper, resume, attention or saving | `docs/incidents.md` |
| Write anything a person reads | `docs/voice.md` |
| Add or change a control, a colour, a size or an animation | `DESIGN.md` |
| Make anything else a person sees | `docs/brand.md` |
| Meet a word you are unsure of | `docs/glossary.md` |

## Commands

```sh
./scripts/check.sh            # all three apps: tests, typechecks, site build
./scripts/check.sh macos      # one of: macos, updates, web

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

Nothing in `check.sh` deploys, signs or publishes. Run it before you say a
change is done.

## Rules that hold everywhere

**No em-dashes in anything a user reads.** Never use an em-dash (or an en-dash
as punctuation) in copy a user reads. Rewrite with a comma, a colon, brackets,
or two sentences. This covers UI strings, release notes, the website, and the
on-device model prompts in `SessionNameGenerator` / `CommitMessageGenerator`,
which must also *forbid* the dash in what they generate. Source comments,
design docs and commit messages are exempt and are full of them. Don't sweep
those, and don't rewrite changelog entries that already shipped. The rest of
how Wortel writes is in `docs/voice.md`.

**Nothing about the user's work leaves the machine.** No event in
`TelemetryEvent` takes a `String`, which makes "could this leak a repository
name" a question the compiler answers. Adding one is the change that breaks the
promise on wortel.sh/privacy.

**Next to nothing to configure.** No user config, no new keys in
`wortel.conf`, and one Settings window (⌘,) that is kept short. When something
seems to need a preference, find the right answer first. A row in Settings is
only for something decided once that truly differs per person, and each one is
argued for in `docs/decisions.md`. What is flipped while working is a checkmark
in the View menu.

**Cost tracks the window on screen**, not the size of the repository or the
number of sessions.

**Nothing destructive without the user choosing it.** Archive rather than
delete, Trash rather than `rm`, and when unsure, keep the thing. The one
exception is a file Wortel made for itself in its cache (a pasted image, a
mark-up note's pictures), removed when it is as old as `docs/decisions.md`
says it may get.

**Publishing is never done unasked.** A release, a deploy of the site or the
Worker, a push to `main`: each needs to be asked for, each time. A feature
branch may be pushed without asking: it reaches nobody, and it is a copy of
the work off this Mac.

## How work reaches people

A branch, the review its size calls for, `main`, then a release, or a beta,
cut from `main`. There is no dev, next or canary branch
(`docs/decisions.md`, 2026-11-26).

- **Each piece of work is a branch of its own**, rebased on `main` before it
  is tried or merged. Pushing it runs no CI: `.github/workflows/macos.yml`
  runs on pull requests and on `main`. A branch that wants CI gets a draft
  pull request.
- **The review before `main` goes by what the change touches.**
  - A small fix: `./scripts/check.sh`, and you read your own diff.
  - A feature: `/code-review` in a session, and the owner has used the build.
  - A large feature, or anything that touches privacy, telemetry or a script
    put into a web page: also the multi-agent cloud review, which only the
    owner can start (`/code-review ultra`). Ask for it, and don't merge
    without it.
  - The keeper, saving or resume: that review, `docs/incidents.md` and the
    keeper's scripts, and it reaches people as a beta first.
- **`main` is where things come together**, not what people run. It is
  released once the owner has used it (the `release` skill's checklist).
- **Releases and betas are cut from `main`**, and `release.sh` refuses
  another branch. While a beta is out, which is a few days, no regular
  release goes out: one cut from `main` would carry the beta's change to
  everyone before the testers have had it.
- **The owner's daily build is `main`, or a branch rebased on today's
  `main`.** Never a branch that is behind it: an older build saves the
  session file back without the fields it doesn't know.

## Working in this checkout

- **Other agents are often working here at the same time.** Before committing,
  read the diff of every file you touched. If a file has hunks that are not
  yours, stage only your own. Never `git add -A`, never `git commit -a`, never
  `git stash`. For anything more than a small change, work in a worktree.
- **Verify, then say so.** Say what you ran and what you saw. If something was
  not checked, say that instead. A claim in a doc that was verified carries its
  date.
- **Measure before the second guess.** When a fix did not work, find out what
  is actually happening before writing another.
- **Keep the docs true.** When behaviour changes, change its doc in the same
  commit. A decision gets a line in `docs/decisions.md`. A doc that is wrong is
  worse than none, because the next agent will follow it.
- **Docs here are written to be safe to publish.** No names of people, no
  account or dashboard ids, nothing private to one machine. Other products are
  named only for facts their own docs or issue trackers state.
- **Commits:** an area and a colon, then a present-tense statement of the new
  behaviour: `Sidebar: a collapsed folder says what it's hiding`. The body
  gives the symptom, the measured cause, what changed and what was verified.
  More in `docs/voice.md`.

## Skills

Procedures live in `.agents/skills/` (Claude Code reads the same files through
`.claude/skills`). Each is one `SKILL.md`.

| Skill | For |
| --- | --- |
| `run-build` | Building the app and replacing the running one without losing its sessions |
| `test-copy` | A throwaway copy of the app, for a test of your own |
| `release` | Cutting and publishing a release |
| `release-note` | Writing the changelog entry for a version |
| `sync-visuals` | Bringing the design canvas and the site's app windows up to date with the app |
| `update-ghostty` | Moving to a newer Ghostty: the weekly report and draft pull request, and the review they leave to you |

## Distribution & Cloudflare

Both sites share one Cloudflare account and the `wortel.sh` zone:
- **updates.wortel.sh**: R2 bucket `wortel-updates`, the Sparkle appcast +
  signed app zips, and the DMG the website downloads (`Wortel-latest.dmg`),
  all published by `macos/scripts/release.sh --publish`.
- **wortel.sh**: the `wortel-web` Worker serving `web/dist` (deployed by
  `web/` → `npm run deploy`).

### The changelog

One Markdown file per release in `web/src/content/releases/`, **named for the
version** (`2026.32.2.md`). It is the only place release notes are written, and
it feeds both the public changelog at `wortel.sh/updates` and the notes Sparkle
embeds in the in-app update dialog. `release.sh --publish` refuses to publish a
version with no note.
