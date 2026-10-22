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
| Work isolated, beside your checkout | ⇧⌘N New Worktree Session | A worktree on a new branch from a fresh default branch; the row is there at once |
| Get to a branch, worktree or pull request | ⇧⌘O Open Branch | Goes to its session, restores the archived one, opens the worktree, checks the branch out, or creates it |
| Try something from where you are | ⌥⇧⌘N Fork Session | The session as it is, changes and conversation, in a worktree of its own |
| Stop | ⇧⌘W, the row's ×, or `exit` | Archived: the worktree and branch stay, the conversation is remembered. Trashed instead when nothing in it is worth keeping |
| Continue | ⇧⌘O, pick it under Archived | The shell starts in the worktree and the agent resumes |
| Find a worktree another tool made | ⇧⌘O, under Not open | Opening it makes a session there; Wortel never deletes it |
| Delete an archived one | Clean Up Worktrees… | Its worktree to the Trash, the archived session with it |

## Decisions

- **One verb to get somewhere.** Open Branch is worktrunk's `switch`, lazygit's
  single field and VS Code's "it's checked out over there, open that": you say
  what, Wortel works out how. Each row says what Return will do before you
  press it, and a branch with a place is listed at that place only, so it can
  never make a second worktree for one that has one (`OpenTarget`).
- **Closing archives.** Conductor, Emdash and Supacode archive; Claude Code
  removes a clean worktree on exit. Both: archive always, then remove if
  there's nothing to keep (`WorktreeCloseDecision`): Wortel's own, clean, every
  commit elsewhere or already in trunk by content. The decision runs after the
  row has moved, because a monorepo's `git status` takes seconds and ⌘W can't.
- **The sidebar shows open sessions only.** A per-folder Archived fold was
  built and dropped: it was clutter under every folder, and Open Branch
  already lists everything with a place.
- **A worktree is just a directory to move to.** Change Directory (`wortel
  cd`) lists the repository's free worktrees beside the sidebar folders, and
  moving there is an ordinary move: the agent's conversation goes along, the
  row gets the branch line, ⌘W then archives it with that worktree. Making a
  new worktree is Fork's job, which also brings the uncommitted changes; a
  worktree a session moves out of stays on disk, shown as "Not open".
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
