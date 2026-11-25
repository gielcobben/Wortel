---
name: update-ghostty
description: Move Wortel to a newer Ghostty (the pinned commit in macos/GhosttyKit/ghostty.ref) and finish the work the pin alone does not do. Reads what changed, fixes the patches, finds behaviour Wortel relied on, ports shell integration and terminfo, verifies, and writes it down. Use on a "Ghostty: vt-x.y.z" draft pull request, on the weekly "Ghostty: N changes for Wortel" issue, or when asked to update or bump Ghostty or pull in a Ghostty fix.
---

# Moving Wortel to a newer Ghostty

Wortel builds Ghostty from one pinned commit. Nothing moves it on its own.

## What is already automatic

`.github/workflows/ghostty-watch.yml` runs every Monday
(`macos/scripts/ghostty-watch.sh`; `DRY_RUN=1` shows what it would do):

- **One issue**, "Ghostty: N changes for Wortel since <pin>", holds the report
  from `macos/scripts/ghostty-news.py`. It gets a comment, which is what
  notifies, when Ghostty tags a new version or a security item appears. It is
  closed when Wortel has caught up.
- **A draft pull request for the newest tag past the pin** (`v*` for the
  app, `vt-*` for libghostty-vt; one, if two came in a week), branch
  `ghostty/<tag>`. It moves `ghostty.ref` (and
  `zig.version` if the tag needs a newer Zig) and nothing else. The macos
  workflow is started on it, so CI already says whether the patch stack
  applies and the tests pass.

What follows is the part that cannot be automated. Moving to 5ebe501 built and
passed every test, and still shipped dead links and a broken copy-on-select in
2026.47.4, because Ghostty had changed what a callback's answer and two
defaults meant (`2d9e3e9`). Step 3 is that lesson.

## When

- **An advisory or a security mention the pin does not have:** now, in its own
  release.
- **A new tag:** in the next release.
- **Commits on Ghostty's main branch alone:** wait for a tag, unless one of
  them fixes something a Wortel user hit.

Every release that moves Ghostty restarts each running shell once, agents
resumed, because a keeper of another Ghostty commit is replaced
(`docs/decisions.md`, "Ghostty is built here, from source"). That is the cost
of a move: batch them, and never move Ghostty in a release for nothing.

## 1. Read the report

```sh
cd macos
python3 scripts/ghostty-news.py                  # pin → newest tag, and main after it
python3 scripts/ghostty-news.py --target <ref>   # pin → a commit of your choosing
```

It keeps blobless clones of Ghostty and libghostty-spm in
`~/Library/Caches/sh.wortel.ghostty/news/`. Each commit is listed once, under
the area that says what it asks of you. Diffs below read from that clone
(`G=~/Library/Caches/sh.wortel.ghostty/news/ghostty.git`); it fetches file
contents as they are needed, so it needs the network.

## 2. Move the pin and make it build

On the draft pull request's branch, or in a worktree on a branch named
`ghostty/<tag>`:

1. `GhosttyKit/ghostty.ref` is the tag's commit (`git --git-dir $G rev-parse <tag>^{commit}`).
   `zig.version` is raised only if the report says so.
2. **libghostty-spm.** Its patch stack is applied before Wortel's. The report
   says whether its main has changes to its patches or build and which Ghostty
   commit its main was last made for. If that is older than the target and a
   patch of theirs fails, look at their main first: move `spm.ref` to it and
   read those changes.
3. `scripts/build-ghostty.sh`. A patch fails loudly on an anchor that moved.
   Wortel's own are `GhosttyKit/Patches/0100` (the keeper's snapshot restore)
   and `0101` (`system-mono`): fix the anchor, keep the hunk's meaning.

## 3. Find what changed for Wortel

Read every commit under these areas, the diff and not only the subject:

- **Config.** `git --git-dir $G diff <pin> <target> -- src/config/Config.zig`.
  For each changed default, check whether `Resources/wortel.conf` sets that key.
  If it does not, Wortel's behaviour changed. Keep the new default or set the
  old one in `wortel.conf` (no inline comments, `docs/building.md`), and say
  which in the commit.
- **C API.** `git --git-dir $G diff <pin> <target> -- include/ src/apprt/embedded.zig src/apprt/action.zig src/terminal/c/`.
  For each action `GhosttyRuntime.swift` handles
  (`grep -o 'GHOSTTY_ACTION_[A-Z_]*' macos/Wortel/Ghostty/GhosttyRuntime.swift | sort -u`),
  check whether what its return value means or what happens when Wortel
  returns false has changed. `ghostty/vt/` is the keeper's
  (`WortelKeeper/KeeperTerminal.swift`).
- **Links.** `src/config/url.zig` is the matcher behind ⌘-click. Put it on the
  hand-check list.
- **Ghostty.app** (`macos/` upstream). Not built into Wortel, but
  `SurfaceView.swift` mirrors its input, IME, clipboard and mouse handling.
  Port a fix there the way `2d9e3e9` did, and say which you did not port and why.
- **Shell integration.** Not picked up by the pin. Port by hand into
  `Resources/ghostty/shell-integration/`, three copies kept in step, and update
  the "Ported on ... against the <pin> pin" list in `docs/debugging.md`.
- **Terminfo.** Not picked up by the pin. Regenerate `Resources/terminfo` as
  `docs/building.md` describes.
- **Terminal, Fonts, Renderer, Input, Build.** These come with the update.
  Skim them for anything a person would see, and add those to the hand-check
  list.

## 4. Verify

```sh
../scripts/check.sh macos          # tests, including the keeper's
scripts/check-terminals.sh         # about 8 minutes
scripts/try-appearance.sh          # light and dark
scripts/try-app-crash.sh           # the snapshot restore, which patch 0100 carries
python3 scripts/verify-agent-status.py
```

Then build the app (the `run-build` skill) and give the person a hand-check
list. Don't drive the app yourself. Always on the list:

- ⌘-click a URL, a path, and a `path:line`
- Select text, then middle-click to paste it. ⌘C with nothing selected reaches the program.
- Typing with an input method (Japanese), Dictation, the emoji picker
- `exit` in a shell closes its session
- A window resize, and scrolling and selecting in Claude and Codex fullscreen

Add whatever step 3 turned up.

## 5. Write it down

- **Commit:** `Ghostty: <tag>, <what changes for a person>`. The body lists
  what was read, what changed for Wortel and how it was handled, what was not
  ported and why, and what was verified and what was not.
- **Docs:** `docs/debugging.md` (the shell integration list and pin),
  `docs/building.md` if the build changed, and a line in `../docs/decisions.md`
  for each default or callback whose meaning Wortel now handles differently.
- **Release note:** fixes a person would notice, in their words, and that
  running shells restart once on this update (the `release-note` skill).
- Mark the draft pull request ready. Merging, pushing to main and releasing
  each need to be asked for.
