# Session naming

How a sidebar row gets its name, who may change it, and why the agent's own
title comes first. The code is `Session.NameSource`, `AgentTitle`, and the
naming section of `SessionManager`; the tests are `AgentTitleTests` and the
name-source cases in `PersistedSessionTests`.

## The problem it replaces

Wortel used to name a session by scraping its screen after a turn ended and
asking the on-device model for two to four words. That is the worst input
(an agent's TUI as drawn, borders and spinner included), at the worst moment
(a turn end, at least 45 seconds after anything happened), for the shortest
output. Worktree sessions were exempt entirely: they were named for their
branch as if the user had typed it, so they never got a name at all. The
evidence was in `sessions.json`: every session had been renamed by hand.

## What other tools do

Every tool that names conversations well names them **from the first
prompt, once**, and then holds still:

| Tool | Source | Regenerated? |
|---|---|---|
| Claude Code | first prompt, small model | only on `/rename` or accepting a plan |
| Codex CLI | first prompt, kept in its sqlite store | no |
| Zed | first message | manual button only |
| Cursor | first message, retitles mid-thread | yes, and users file bug reports about it |
| Warp | AI naming on each prompt | yes, and it overrode `/rename` |
| Conductor | branch or PR title | follows the PR |
| cmux | transcript head and tail, `claude -p` | on turn end, 180 s cooldown |

Cursor and Warp are the cautionary tales: a name that keeps changing under
you is worse than one that is slightly stale, and nothing may beat a rename.

## The rule: the agent names the session, Wortel frames it

**Claude Code already generates the name.** The moment a first prompt is sent
it asks a small model for a title ("Debug git panel display issues with
worktrees"), writes it to its transcript as an `ai-title` record, and pushes
it into the terminal title as `✳ <title>` at rest and `◐ <title>` (animated)
while working. `/rename` replaces the text; a new conversation gets a new
one. Wortel receives every title change already (`SessionManager.titleChanged`,
for busy detection), so adopting the name is a parse and a compare
(`AgentTitle`), costs no model call, needs no macOS 26, and lands seconds
after the first prompt. It is also the same title Claude's own `/resume`
picker shows, so the sidebar and the agent agree.

**Where a name came from decides who may replace it.** `Session.NameSource`,
in precedence order:

| Source | Set by | Replaced by |
|---|---|---|
| `placeholder` | the directory at creation; the branch for a worktree session | anything |
| `model` | the on-device model, from the screen (`SessionNameGenerator`) | agent, user, or a better model guess |
| `agent` | the agent's terminal title | a new agent title, or the user |
| `user` | an inline rename, or `wortel rename` | the user only |

So the model only fills in where no agent has spoken (a plain shell running a
long build, an agent CLI that sets no title), an agent title always wins over
a guess, and a user rename is final. Nothing periodically renames an agent
session: its title changes only when the agent's does.

**A worktree session is named for its task and shows its branch underneath.**
The branch is where the work lives, not what the work is. The session starts
out called after the branch (a placeholder, so the agent may replace it), and
once it has a real name the branch moves to a second line on the row, with the
same glyph as the toolbar's branch chip. The row is two lines tall only in
that state (`Session.showsBranchLine`), which is why the sidebar's identity
snapshot carries the set of tall rows: height is the one visual fact the
hosted SwiftUI row can't change on its own. Sessions persisted before the
branch was recorded ask git for it once at restore.

## What `AgentTitle` accepts

A title counts as an agent's only if it *leads with a marker glyph*: Claude's
`✳` and its spinner frames (half circles, braille, the dingbat asterisks),
Gemini's `✦ ⏲ ◇ ✋`. A shell's own title never does, so it is ignored rather
than adopted. What follows the glyph is then filtered for *state* rather than
a name ("Working", "Ready", "Action Required", the agent's own name) and for
an echo of the directory, both of which would otherwise become sessions
called "Working" or "wortel". The marker set is deliberately wide: a frame it
misses does not fail, it silently leaves a session on its placeholder.

## Persistence

`sessions.json` records `nameSource` (the raw value) and `worktreeBranch`. The
flag it replaced, `nameIsUserSet`, is still read: `true` was a rename and
becomes `user`; `false` was a default or a model guess and becomes
`placeholder`, since both are things anything may now replace. A file with
neither flag predates auto-naming altogether and is treated as user-named, so
the feature never relabels a session someone settled on long ago.

## Not done yet

The model path still reads the screen. The follow-up is to feed it the
conversation instead, the way cmux does (the first prompt plus the latest
one, from the transcript), and to ask for Claude's style: sentence case, verb
first, three to seven words. Codex stores its thread titles in
`~/.codex/state_5.sqlite` (`threads.title`) and sets no terminal title, so it
would need that path too.
