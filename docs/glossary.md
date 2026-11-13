# Glossary

The words this project uses, and what each one means here. Several are ordinary
words with a narrower meaning than you would guess. Use them the same way in
code, docs and copy.

## The window

**Session.** One row in the sidebar: a named shell in a directory, with its own
terminal, tabs and git panel state. The unit of everything. Not a tab.

**Folder.** A group of sessions in the sidebar. A session is in a folder when
its name has a slash: the folder is the part before the last one. A folder also
carries a directory (its **folder root**), where new sessions in it start. It is
not a folder on disk, which is why the menu says "Ungroup Sessions".

**Main area.** The middle of the window. Holds the session's own terminal, which
never leaves it and cannot be closed.

**Side column.** The trailing column: Changes, History, Files, side terminals,
previews, browsers. Older docs and some code call it the **inspector**.

**Bottom strip.** The row under the main area (⌘J).

**Tab.** One thing in one of those three rows: a terminal, a pane, a file, a
browser. The terminal engine has no tabs and no splits of its own. These are
Wortel's.

**Pane.** One of the three git and file views: Changes, History, Files.

**Workspace.** A session's whole arrangement of tabs across the three rows
(`WorkspaceTabs`).

**Surface.** One libghostty terminal, and the view that hosts it
(`SurfaceView`). Created lazily, then kept alive and hidden, never rebuilt.

**Preview.** A file opened to look at: source, diff, rendered Markdown, or
Quick Look. A tab by default.

## Sessions and their life

**Origin cwd.** The directory a session was born in. It never moves. `cwd`
follows the shell around; new sessions inherit the origin, not the drift.

**Worktree session.** A session whose directory is a git worktree of its own,
so an agent in it cannot disturb another.

**Archive.** What closing a worktree session does: the shell ends, the worktree,
branch and conversation are kept, and ⌘P brings it back. Not deletion.

**Owned.** A worktree or branch Wortel made, recorded by a marker in git, never
guessed from a path. Wortel only ever removes what it owns.

**Lead.** In a multiple selection, the one item that is "the" selection: the
session on screen, or the file whose diff is showing.

**Data folder.** `~/Library/Application Support/Wortel`, or whatever
`WORTEL_DATA_DIR` names. Sessions, the keeper's socket and agent markers live
there. One running Wortel per data folder.

## Survival

**Keeper.** `wortel-keeper`, the small process that holds every pty so shells
are not the app's children. Never named in the UI.

**Attach, detach.** The app taking over reading a session's pty from the keeper,
and handing it back. Only one of the two reads at a time.

**Replay.** What the keeper buffered while nothing was attached, written into
the new terminal on attach. Bounded, and not scrollback.

**Resume.** Typing an agent's own "continue this conversation" command back
into a session after a relaunch or a recovery, by exact conversation id.

## Agents

**Agent.** A coding agent's command-line program running in a session: Claude
Code, Codex, Pi and the like. A guest. Wortel installs nothing into it.

**Marker.** A small file in the data folder, written by the shell integration
while an agent runs, saying which agent and since when. It exists only during a
run.

**Busy.** The session is working: the spinner.

**Attention.** The session wants you: a dot, the Dock badge, a notification. It
has a kind, loudest first: **needs input**, **failed**, **turn done**,
**finished**. A louder kind is never downgraded to a quieter one.

**Turn.** One prompt and the agent's whole answer to it. A turn end counts only
when the agent's own transcript shows one.

**Signal.** Something a program says about itself through the terminal: OSC 9;4
progress, a title spinner, a notification escape, a bell.

**Screen tier.** The fallback when a program says nothing: watching whether its
screen keeps changing.

**Away.** The Mac has not been touched for a minute. Changes what an attention
signal does.

**Viewing.** Wortel frontmost, its window on screen, the session selected, and
not away. Attention is not raised for a session being viewed.

## The command

**`wortel`.** The command-line interface, bundled in the app and on the `PATH`
of every shell Wortel starts. It exists inside a session and nowhere else.

**Reach.** The four verbs that act on another session: `list`, `read`, `send`,
`wait`.

## Configuration and releases

**Zero-config.** There is nothing for a user to configure, on purpose.

**`wortel.conf`.** The bundled, read-only Ghostty config that is the whole
configuration. No inline comments: a `#` after a value becomes part of it.

**Version.** `<ISO year>.<ISO week>.<nth release that week>`, such as
`2026.46.5`. Derived from the date and the live feed. Nobody picks one.

**Release note.** One Markdown file per version in `web/src/content/releases/`.
The changelog and the update dialog both render from it.

**Appcast.** The Sparkle feed at `updates.wortel.sh/appcast.xml`.

## The site

**The lake.** The foggy-lake photograph the site's colours are sampled from, and
by extension the site's look.

**Stage.** A scene on the homepage: a heading, then a real app window standing
on a photo, with chapter tabs over it.

**Chapter, film.** A stage plays through chapters by itself, like a short film.
Each chapter puts the window in a state.

**The canvas.** The design file the app's panes are drawn on. The site's windows
are generated from it and never edited by hand.

**1:1.** The app shown at its real size. Never scaled.
