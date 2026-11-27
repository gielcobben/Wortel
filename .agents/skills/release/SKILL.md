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

1. **On `main`, nothing uncommitted.** `--publish` refuses a dirty tree and
   any branch but `main`. Don't reach for `--allow-dirty`: the release is then
   not rebuildable. `--allow-branch` is for an emergency fix that must ship
   before what is on `main` can, and only when the owner says so.
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
4. **How far behind the pictures are.** `../web/scripts/opmaak/drift.sh --count`
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
6. **Finder can be scripted from here.** `scripts/make-dmg.sh` has Finder lay
   out the DMG's window, which needs the app running the release to be allowed
   to control Finder (System Settings > Privacy & Security > Automation). The
   first time, macOS asks; nobody answering that prompt stalls the release.
   The script stops after notarizing the app if Finder refuses, so check first:

   ```sh
   osascript -e 'tell application "Finder" to get name of startup disk' >/dev/null && echo ok
   ```
7. **Checks against a real machine**, for what the release touches:
   `scripts/verify-running-jobs.py` for `Wortel/Processes/`,
   `scripts/try-git.sh` for `Wortel/Git/`, `scripts/try-keeper-loss.sh` for
   keeper recovery, `scripts/check-terminals.sh` for anything touching a
   terminal or the keeper. The script itself runs `WortelTests` and the `updates/`
   tests.
8. **The build has been used.** There are no UI tests. Someone has run this
   code as an app and seen its terminals draw.

## The command

```sh
./scripts/release.sh --publish --no-install
```

It derives the version, builds Release against the pinned packages, signs,
notarizes, staples, EdDSA-signs the zip, makes and notarizes the DMG,
regenerates the appcast, uploads the zip, the DMG and the appcast to the
`wortel-updates` bucket and redeploys wortel.sh, whose Download button is the
DMG.

### A beta

```sh
./scripts/release.sh --publish --beta --no-install
```

For a change that can't be taken back once it is out (a keeper protocol
change, saving and resume, anything that big), when the maintainer wants a few
testers on it first. Same checks as above, same version sequence, and cut from
`main` like any release: the change has merged first. A beta cut from a branch
is taken away from its testers by the next regular release. **While a beta is
out, no regular release goes out** until it has been promoted: one cut from
`main` would carry the beta's change to everyone before the testers have had
it. What differs:

- The note's frontmatter has `beta: true` after `summary`. The script refuses a
  beta without it, and a regular release with it (any spelling but `true` or
  `false` is refused). The note shows in the testers' update dialog and on
  no list on wortel.sh: not the changelog, its pages, the feed or the
  sitemap. Its dialog fragment, `release-notes/<version>.html`, still goes up
  unlinked with the next site deploy. The update popover has no What's New
  for a beta.
- The appcast item is tagged for the beta channel, so only Macs on it are
  offered the version. The site, `Wortel-latest.dmg` and the site deploy are
  left alone.
- The build wears `Wortel/AppIconBeta.icon` instead of `AppIcon.icon`, and
  calls itself "Wortel Beta" (`WORTEL_DISPLAY_NAME`, put in a localized
  `InfoPlist.strings` by `macos/scripts/display-name.sh`; the bundle is still
  `Wortel.app`). The script refuses to publish a beta without either, and a
  regular release with either.
- The output ends `==> Published <version> as a beta` and prints
  `https://updates.wortel.sh/Wortel-<version>.dmg`. That link is what the
  maintainer hands a tester. Installing it once puts their Mac on the channel;
  Settings ▸ Beta updates takes it off.
- The maintainer's own Mac, taking the update in-app because of
  `--no-install`, is offered the beta only once it is on the channel too. The
  maintainer runs this once, in their own shell:
  `defaults write com.gielcobben.Wortel WortelBetaUpdates -bool true`.
- The next regular release's note covers what the betas since the last
  regular one carried: everyone else never saw those notes.

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
