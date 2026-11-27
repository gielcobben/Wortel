---
name: release-note
description: Write the release note for a Wortel version, the one Markdown file that feeds both wortel.sh/updates and the in-app update dialog. Use when asked to write, draft or fix a changelog entry or release notes, or before publishing a release that has no note yet.
---

# Write a release note

One file per release: `web/src/content/releases/<version>.md`. The filename is
the version and the only place it is written. Read `docs/voice.md` first; this
is the short form for this one kind of writing.

## Find out what changed

```sh
git log --format='%s%n%b' "$(git log --format=%h --grep='^Release 20' -1)"..HEAD
```

Read the bodies, not only the subjects. Then translate: the note is for the
person using the app, and a commit is for whoever reads the source. Leave out
anything they cannot see or feel.

## The file

```markdown
---
date: 2026-11-12
title: Screen readers can read the terminal
summary: VoiceOver and read-aloud apps can now read what's in Wortel's terminal, follow your selection and find where each word sits on screen, as they do in Terminal.app.
---

**Screen readers can read the terminal.** Apps that read text aloud or describe the screen, like VoiceOver, ask macOS what an app is showing. Until now Wortel's terminal told them nothing. It now answers as a text area: ...

**Send Feedback.** Help ▸ Send Feedback… opens an email to ...
```

- **Frontmatter:** exactly `date`, `title`, `summary`, in that order, unquoted.
  A beta (`release.sh --publish --beta`) is named for its bundle version,
  `2026.48.4b1.md` (shown as "2026.48.4 beta 1"), and adds `beta: true` after them: the note
  then shows in the testers' update dialog and on no list on wortel.sh (its
  dialog fragment is still deployed, unlinked). The next
  regular release's note covers everything the betas since the last regular
  release carried, because everyone else is offered that release and none of
  the betas.
  The build fails when `date` is not a date or `title` is missing. `summary` is
  optional to the schema and not to us: it leads the update dialog.
- **Title:** sentence case, no full stop. The headline outcome, or two joined
  by ", and".
- **Summary:** one to three full sentences. It leads the update dialog, so it
  has to stand alone. For a fix: what went wrong, then what is true now.
- **Body:** short paragraphs, each opening with a bold lead that ends in a full
  stop, then two to five sentences. No headings, no version, no date, no code
  blocks, no images. Small items close the note under `**Fixes.**` or
  `**Smaller things.**`.
- **Length:** 90 to 230 words for a fix, 200 to 500 for a feature release.

## How it reads

- Address "you". Wortel is "Wortel", never "we" or "our".
- A fix runs in three beats: what you saw, the cause in one plain clause, what
  happens now. Past tense for the old behaviour, present with "now" for the new.
- Say what did not change: "A plain click or drag still goes to the agent, as
  before."
- Concrete particulars: key glyphs (⇧⌘N), menu paths (Help ▸ Send Feedback…),
  quoted UI strings, commands in backticks, real numbers.
- Translate internals. The keeper is "the process that keeps your terminals
  running". No class names, no commit hashes.
- Compare to what a Mac user knows: "as in Finder", "as they do in Terminal.app".
- A removal is stated flatly, with what replaces it.
- A change to what usage data holds is always disclosed, with what is still
  never collected.
- British spelling: colour, recognised, centre, grey.
- Contractions are fine: it's, you're, doesn't.

## Never

Em-dashes or en-dashes as punctuation. Exclamation marks. Emoji. "We". Marketing
adjectives (powerful, seamless, blazing). A feature described by how it was
built.

## Check

```sh
grep -n '[—–]' web/src/content/releases/<version>.md    # must print nothing
cd web && npm run build                                  # the schema check
```

Notes that already shipped are not rewritten, even where an older one breaks
these rules.
