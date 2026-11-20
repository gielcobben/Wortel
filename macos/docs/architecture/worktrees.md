# Worktrees in the code

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**A new worktree gets the ignored files it needs to run** (`WorktreeInclude`):
whatever `.worktreeinclude` names in the checkout it was made from (gitignore
syntax, the convention Claude Code, Codex, Conductor and Orca share), else
`.env*`. Only ignored, untracked files; never into an existing file or a nested
repository; cloned, not copied, where APFS allows. The listing is
`ls-files --others --ignored --directory`, which reports `node_modules` as one
line instead of walking it, and a pattern only looks inside an ignored directory
when it names a path there. A worktree that already existed is never written
into. Anything that didn't copy is held on the preparing page
(`WorktreePreparation.warnings`) until "Open Session", because the terminal
replacing the page would hide it.

**Worktrees: the session is the unit** (`docs/worktrees.md`). You manage
sessions; a worktree is where one lives. One way in: ⌥⇧⌘N New Worktree
Session (`BranchSheet`: a placeholder name selected so Return is instant, From,
and Location, which writes the repository's `wortel.worktreePath`; an existing
branch or a `#123` in the name field checks that out; `wortel new --worktree`
skips it). **Starting a session has four ways and only four** (⌘N, ⌥⌘N at
home, ⌥⇧⌘N, ⌘O): Open Branch, Fork Session, Change Directory (`wortel cd`) and
New Folder were all cut on 2026-11-09 for being more ways in than anyone kept
apart. Don't add a fifth without that argument. (New Terminal, ⌃⌘N, is ⌘N
without the command Settings names and exists only while it names one:
`SessionStart.plain`.) One way out: closing (⇧⌘W, ×, `exit`) a session that lives in a
worktree **archives** it (`SessionManager.archive`), then, after the row has
moved, inspects the worktree and Trashes it only when there's nothing to keep
(`WorktreeCloseDecision`). Archived sessions are in `archived-sessions.json`,
never `sessions.json`, which an older build would start them from; restoring
one goes through the same `restoredSession` launch uses, agent resume and all.
The sidebar shows open sessions only: **⌘P** is where archived ones are
found once you type (`OpenTarget`, listed under the matching sessions), with
the worktrees no session is in, whoever made them ("Not open"), from one cached `git worktree list` per repository
(`worktreeListings`, refreshed by a vnode watch on `.git/worktrees` and after
creates and archives; never per row or on a timer). An Archived fold per
folder was tried and dropped as clutter.

**Any linked worktree is a worktree; only Wortel's are Wortel's to remove.**
`GitWorktree.linked` reads the nearest `.git` file on every `cd` (no git): the
row gets the glyph and branch line, ⌘O files it with its repository.
Ownership is a **marker** in the worktree's git folder and
`branch.<b>.wortelCreated` in git config (`GitWorktree.Ownership`), not a path;
`~/.wortel/worktrees` and `worktree/` still count, for what was made before.
Never lock a worktree, ours or anyone's. A repository may put its worktrees
elsewhere with `git config wortel.worktreePath` (a folder or a `{repo}`/
`{branch}` template; the New Worktree sheet's Location field, or `includeIf` for a
whole tree of repositories); one inside the repository goes in `info/exclude`.
A generated branch is renamed for the session's name while unpushed
(`GitWorktree.mayRename`); the folder never moves, since agents key history by
directory, and a folder that held a worktree (or Claude history) is never
reused. A worktree row is marked as preparing *before* it's selected
(`makeSession(prepare:)`): selecting starts the shell, and one started with no
directory came up in the keeper's, `/`.

**Removing a worktree never loses work without you choosing it.** Closing a
session archives it (above); Clean Up Worktrees… goes through `WorktreeCleanupSheet`, which inspects first
(`WorktreeCleanup.inspect`): uncommitted or untracked files, something running
there or another session in it, a lock, or a folder that isn't a checkout any
more → **blocked**, with the reason; commits found on no other branch or
remote → the folder may go, the branch stays unless you tick it; otherwise
**safe**, folder and (Wortel-made) branch both. Removal re-inspects, moves
the folder to the **Trash** (a clean status says nothing about an ignored
`.env`), then drops only that registration (`worktree remove` on the now-missing
folder, not `prune`, which would also forget a worktree on an unmounted
volume; `addWorktree` likewise drops only a stale registration in its way).
Only worktrees Wortel made, and only branches it created, are ever Wortel's to
remove; a commit count git can't give is treated as "may have commits". A branch whose commits are on no other branch
but whose **work is already in the default branch** (squash or rebase merged,
the way most pull requests land) is safe too (`WorktreeReport.mergedInto`,
`GitService.isMerged`): `merge-tree --write-tree` of the branch into trunk
gives trunk's own tree. Its cost follows the branch, not trunk's history. A
branch that changed nothing since it forked is never "merged" (its commits are
all it has), and trunk editing the same lines since says no, which keeps the
branch: the safe way to be wrong. The git panel says "Merged into origin/main"
for the clean worktree on screen, cached per (HEAD, trunk), and offers Close
Session when the session lives there (closing is how a worktree is put away).
Bring Here counts an archived session's worktree as in use: restoring it
needs its branch.
