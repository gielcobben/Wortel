# Voice

How Wortel writes: on the site, in the app, in release notes, and in its own
docs and commits. Read this before writing anything a person will read.

## The sound

Plain, exact and calm. A careful engineer telling a friend what the thing does
and why it does it that way. Never selling.

- **Say the thing, then the reason.** "Closing archives. A monorepo's
  `git status` takes seconds and ⌘W can't."
- **Short sentences, ordinary words.** If a sentence needs reading twice, it is
  two sentences.
- **Concrete over general.** A number, a key, a filename. "870 ms against
  20 ms", not "much faster". If there is no measurement, don't imply one.
- **Say what it does not do, and mean it.** "There is no settings window, and
  there is no dotfile. This is the feature."
- **Name the cost.** When a choice gives something up, say what.
- **Honest about not knowing.** "The cause was never found." "Unknown" is a
  real answer, never rounded down to "no".
- **Dry, once in a while.** "You get your afternoons back." One per page at
  most, and never a joke that needs an exclamation mark.

## Hard rules, for anything a user reads

This covers UI strings, notifications, the website, release notes, and the
prompts for the on-device models (which must also forbid these in what they
generate).

- **No em-dash, and no en-dash as punctuation.** Use a comma, a colon, brackets
  or two sentences. It reads as machine-written, and here it stands out.
- **No exclamation marks. No emoji.**
- **No "we" or "our".** The app is "Wortel". The reader is "you".
- **No marketing adjectives:** powerful, seamless, blazing, effortless,
  beautiful, magical, revolutionary, next-generation. If the sentence still
  works without the adjective, it never needed it.
- **British spelling:** colour, centre, grey, recognised, behaviour.
- **Real glyphs for keys:** ⌘ ⇧ ⌥ ⌃, in that written order as macOS shows them
  (⇧⌘N). Menu paths with ▸ (Wortel ▸ Check for Updates…). An ellipsis is one
  character.
- **Code type for what you type:** `wortel new --branch fix/1482`.

`scripts/check.sh` fails the build if an em-dash reaches the built site.

## By place

### The site

The homepage is the pitch and `/docs` is the manual. When a paragraph starts
explaining how something works instead of what it does for you, it moves to
`/docs`. Copy lives in `web/src/data/site.ts` and nowhere else.

Headings are two-tone: a claim, then its explanation.

> **Sessions, not tabs.** A tab is a number you have to remember. A session is
> a name you chose.

> **Quit the app, keep the work.** Your shells are not the app's children.

Each section makes its point once and stops. FAQ answers are written to stand
alone, because they get quoted without the page around them.

### The app

- **A menu item names what happens, in the user's terms.** "Ungroup Sessions",
  not "Delete Folder", so it cannot read as touching the disk.
- **A destructive item says where the thing goes.** "Move to Trash".
- **A message that blocks says why**, in a clause, and what to do. No error
  codes, no "Oops", no "Something went wrong".
- **A notification is the news itself:** the start of the agent's answer, not
  "Task complete".
- Title case for menu items and buttons, as macOS does. Sentence case for
  everything longer.
- Internals never surface. There is no "keeper" in the UI. It is "the process
  that keeps your terminals running", and usually it is not mentioned at all.

### Release notes

The `release-note` skill has the format. The shape of a fix is three beats:
what you saw, the cause in one plain clause, what happens now.

> A plain click or drag still goes to the agent, as before.

> Wortel keeps none of it itself: it reads the history the agents already keep.

Notes that shipped are never rewritten.

### Docs in this repository

Docs, source comments and commit messages are for whoever reads the source. The
dash rule does not apply to them, and older ones are full of dashes. Don't sweep
those. New ones tend to follow the rule anyway, because the habit carries over.

A design doc here records the reasoning, not only the result:

- It opens with what the thing is and the problem it replaced.
- **Decisions** give the choice, the reason, and what was tried first.
- **Not done, on purpose** and **Known limits** are sections, not apologies.
- A claim that was checked carries its date: "Verified (2026-11-11)".
- It names the trap for the next person: "Adding the flag back 'for
  correctness' is the trap."

A comment in the source explains why, never what. The best ones say what
happened when it was done the other way.

When behaviour changes, change the doc in the same commit. A doc that is wrong
is worse than none: an agent will follow it.

### Commit messages

```
Sidebar: a collapsed folder says what it's hiding
Git panel: pull, fast-forward only
Keeper: back to starting it directly; the launchd agent did not help
Attention: no dot for a turn that never happened
```

- **Subject:** an area and a colon, then a present-tense statement of the new
  behaviour or the finding. Not a command. About 60 characters.
- **Areas:** Sidebar, Sessions, Git panel, Worktrees, Keeper, Attention,
  Preview, Files, CLI, Shell integration, Telemetry, Release, Website, Updates.
- **Body:** the symptom as it was reported, the cause as it was measured, what
  changed, the alternative that was rejected, and what was and was not
  verified. Numbers where there are numbers.
- A release is two commits: `Release note <version>: <title>`, then
  `Release <version>: <title>`.

## Instead of

| Not | But |
| --- | --- |
| Blazing-fast session switching | Switching costs a single frame |
| We've added powerful worktree support | Each agent gets its own branch and its own files |
| Seamlessly resume your work | An agent that was thinking when you quit is still thinking when you come back |
| Oops! Something went wrong | The worktree has uncommitted changes, so it was kept |
| Fully customisable | Nothing to configure, on purpose |
| Fixed a bug with notifications | A notification no longer arrives for an answer you already read |
