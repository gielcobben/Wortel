---
name: release
description: Cut and publish a Wortel release with macos/scripts/release.sh. Covers the checks before, the one command, how to tell it really published, and what never to do. Use when asked to release, publish or ship a new version of the macOS app.
---

# Release Wortel

Publishing is public and hard to take back: every installed copy offers the
update within a few hours. Do it only when asked to, in so many words. A go-ahead for one
release is not a go-ahead for the next.

All commands run from `macos/`.

## Before

1. **On `main`, nothing uncommitted.** `--publish` refuses a dirty tree. Don't
   reach for `--allow-dirty`: the release is then not rebuildable.
2. **There is a release note** at `web/src/content/releases/<version>.md`. The
   version is `<ISO year>.<ISO week>.<nth release that week>` and the script
   derives it from the live feed, so work out which one is next before writing
   the file. The `release-note` skill covers the writing. Publishing without a
   note is refused before anything is built.
3. **What's new is on wortel.sh/docs.** For each feature in the note that
   someone would look up (a menu item, a shortcut, a `wortel` verb, a change
   to how something behaves), check `web/src/data/site.ts`: the command table,
   the shortcuts table, `DOCS_SECTIONS` and the FAQ. Add what's missing or now
   untrue, in its own commit before the release, since `--publish` redeploys
   the site. A new verb also belongs in `macos/docs/wortel-command.md`.
   2026.47.1 shipped Remind Me with no word of it on /docs.
4. **How far behind the pictures are.** `web/scripts/opmaak/drift.sh --count`
   prints how many commits have touched code that draws since the design
   canvas, and so the app windows on wortel.sh, last showed the app. It never
   holds a release up. Say the number when you hand over, and when it is
   large, that the `sync-visuals` skill is the way to bring them level.
5. **Notarization can log in:**

   ```sh
   xcrun notarytool history --keychain-profile notary >/dev/null && echo ok
   ```

   If the profile is missing, ask the maintainer to store it again (the command
   is at the bottom of `scripts/release.sh`). Don't go looking in the Keychain.
   It has gone missing between this check and the upload before (2026-11-03),
   so see "After".
6. **Checks against a real machine**, for what the release touches:
   `scripts/verify-running-jobs.py` for `Wortel/Processes/`,
   `scripts/try-git.sh` for `Wortel/Git/`, `scripts/try-keeper-loss.sh` for
   keeper recovery, `scripts/try-replay-modes.sh` for the keeper's replay. The script itself runs `WortelTests` and the `updates/`
   tests.
7. **The build has been used.** There are no UI tests. Someone has run this
   code as an app and seen its terminals draw.

## The command

```sh
./scripts/release.sh --publish --no-install
```

It derives the version, builds Release against the pinned packages, signs,
notarizes, staples, EdDSA-signs the zip, regenerates the appcast, uploads to the
`wortel-updates` bucket and redeploys wortel.sh.

**Always `--no-install` when you are inside Wortel**, which is nearly always.
The install step removes `/Applications/Wortel.app` and copies the new one in.
The running keeper, which holds every session's shell, executes out of that
bundle, and so does the `wortel` command on every session's `PATH`. The new
version is taken the way a user takes it: Wortel ▸ Check for Updates…, by the
person, when they are ready.

## After

- **Read the output for `==> Published <version>`.** That line is the proof.
  Don't go by the exit code alone: on 2026-11-03 a run whose notarization had
  failed was first taken for a success.
- Commit what the script changed (`releases/appcast.xml`, `releases/BUILD`) as
  `Release <version>: <title>`, after the note's own commit
  `Release note <version>: <title>`.
- Say that the installed app is still the old one, and that the update is in
  the menu.

## Never

- **Deltas.** `generate_appcast` runs with `--maximum-deltas 0` and stays that
  way. Full zips only.
- **`--republish`**, unless nobody can have downloaded that version yet. Sparkle
  only offers a version strictly greater than the one installed, so anyone who
  took the first build is stranded on it. This happened with 2026.31.2.
- **A wrangler upload without `--remote`.** It writes to the local simulator and
  the feed 404s.
- **Pruning the bucket.** The script only adds. Old versions stay.
- **A new protocol version in the keeper** as part of an ordinary release. A
  bump ends every running shell on update. Additions are optional fields.
