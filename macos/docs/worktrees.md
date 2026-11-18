# Worktrees

How Wortel handles git worktrees, and why. Written after a survey of the field
(October 2026): agent apps (Conductor, Superset, Emdash, Orca, Supacode, Codex,
Claude Code, Cursor, Vibe Kanban, cmux, Agent of Empires, Claude Squad,
ccmanager, Crystal, uzi), git clients (VS Code, JetBrains, Zed, Fork, Tower,
GitKraken, SourceGit, lazygit, GitHub Desktop, GitButler, jj) and worktree
CLIs (worktrunk, gtr, workmux, Phantom, wtp, git-wt, gwq).

## The model

**The session is the unit; the worktree is where it lives.** Every app that
got this right hides the worktree behind the thing you're working on. You
start sessions, stop them and come back to them; Wortel makes, keeps and
removes worktrees under them.

| You want to | You do | What happens |
|---|---|---|
| Work isolated, beside your checkout | ⇧⌘N New Worktree Session, then Return | A worktree on a new branch from a fresh default branch; the sheet's From and Location rows change either |
| Work on an existing branch or pull request | ⇧⌘N, its name or `#123` in the name field | Checks it out in a worktree of its own; `wortel new --branch` and `--pr` do the same |
| Stop | ⇧⌘W, the row's ×, or `exit` | Archived: the worktree and branch stay, the conversation is remembered. Trashed instead when nothing in it is worth keeping |
| Continue | ⌘P, type its name, pick it under Archived | The shell starts in the worktree and the agent resumes |
| Find a worktree another tool made | ⌘P, under Not open | Opening it makes a session there; Wortel never deletes it |
| Delete an archived one | Clean Up Worktrees… | Its worktree to the Trash, the archived session with it |

## Decisions

- **Four ways in.** ⌘N here, ⌥⌘N at home, ⇧⌘N here on a branch of its own,
  ⌘O somewhere else. Each starts the command Settings names for new
  sessions, if it names one; New Terminal (⌃⌘N) is ⌘N without it. Open Branch (⇧⌘O, one field for every branch, worktree and pull
  request), Fork Session and Change Directory (`wortel cd`) were built and
  cut: seven ways to start something was more than anyone kept apart. What
  only Open Branch did, finding an archived session or a worktree nobody's
  in, is ⌘P's now, once you type (`OpenTarget`).
- **Closing archives.** Conductor, Emdash and Supacode archive; Claude Code
  removes a clean worktree on exit. Both: archive always, then remove if
  there's nothing to keep (`WorktreeCloseDecision`): Wortel's own, clean, every
  commit elsewhere or already in trunk by content. The decision runs after the
  row has moved, because a monorepo's `git status` takes seconds and ⌘W can't.
- **The sidebar shows open sessions only.** A per-folder Archived fold was
  built and dropped: it was clutter under every folder, and ⌘P finds
  everything put away.
- **Archived sessions live in their own file** (`archived-sessions.json`): an
  older build reads `sessions.json` and would start them as live shells.
- **Show everything git knows; delete only what you made.** Hiding foreign
  worktrees (Orca's default) and deleting or locking them (Cursor's cap,
  Codex's sweep, Claude Code desktop, Supacode #533) are the field's top
  complaints. Ownership is a marker in the worktree's git folder and a
  `branch.<b>.wortelCreated` config key, never a path. Wortel locks nothing.
- **Name the branch from the work.** Superset, Orca and Conductor rename the
  placeholder branch once the work has a name. Wortel does it once, only while
  the branch was never pushed and is checked out in that worktree alone. The
  folder is never renamed and never reused: agents key their history by
  directory (Orca's retired-name registry exists for this).
- **Where worktrees go.** `~/.wortel/worktrees/<repo>/<branch>` by default,
  outside every repository (inside, they trip watchers, test runners and
  JetBrains, and double-load `CLAUDE.md`). A repository can name its own
  place in git config, `wortel.worktreePath`, which `includeIf` can set for a
  whole tree of repositories; inside the repository it goes in `info/exclude`,
  never `.gitignore`. Two repositories with the same name get two folders.
  ⇧⌘N's sheet shows the place and changes it for the repository, not for one
  worktree: a place you'd pick once is a place you'd pick every time.
- **⇧⌘N asks, but Return is the old instant path.** It was a no-sheet
  command for a while (2026.43); choosing the base and the place in one form
  was missed. The placeholder name arrives selected, so the fast path costs
  one keystroke and typing names the branch.
- **Cost follows the screen.** One `git worktree list` per repository with a
  folder, cached, refreshed when `.git/worktrees` changes. No git per row, no
  timers, nothing that writes the index from the background. Supacode's
  105-worktree process storm (#830) and FSEvents loop (#842), and uzi's and
  Claude Squad's index writes, are what this avoids.
- **Not planned:** setup or run scripts (files only, `.worktreeinclude`), PR or
  CI status on rows (needs `gh` or the network), pre-made worktrees, locking,
  GitButler-style virtual branches, auto-deleting anything unmerged or foreign.

## Mistakes the field made, to keep not making

1. Recycling or deleting a worktree another session still uses (Claude Code
   desktop #77268, Codex #48196).
2. Deleting a branch silently, even with an open PR (Orca #20875).
3. A cleanup that deletes a parent folder holding live worktrees (Supacode #878).
4. Deleting worktrees by a global cap, including ones made by hand (Cursor).
5. A shell restored to the repository root instead of its worktree (cmux
   #19306), or started in `/` because its folder wasn't there yet (Wortel,
   fixed in ad8ab2e).
