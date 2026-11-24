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

**Every other agent gets the same thing from its first prompt.** Only Claude
titles itself. For everyone else, Wortel reads the one input every agent has
in common: the prompt the user types into it. Wortel owns the pty, so every
keystroke passes through `PtyHost.write` on its way to the agent; while an
agent is freshly launched (the marker file says when), a `PromptTap` on that
path reconstructs typed lines (`TypedLineBuilder`: backspace, ctrl-U/W,
bracketed paste, the kitty keyboard protocol, and the terminal's own query
replies all handled or dropped; it reads one write at a time, since libghostty
writes each key press and each reply separately, which is what keeps a reply
like the background colour out of the prompt; a reply whose opening `ESC P`
or `ESC _` arrives alone is held until it ends, after a session was named
`>|ghostty 1.3.1Gi=31;O…` from Claude's XTVERSION and kitty graphics
answers), and the first line that is a prompt rather
than a dialog answer or a slash command (`FirstPrompt.accept`) goes to the
on-device model with a prompt tuned to Claude's style. A prompt on the
agent's command line (`codex "add a changelog page"`) is taken as is. Without
Apple Intelligence the title is the prompt's first sentence, cut at a word,
which is what Cursor and Codex show.

This is the approach the field converged on. cmux and the herdr renamer
plugin both name from the first prompt, once; they get the prompt by
installing hooks into each agent's config files and summarise with a
per-agent cloud subprocess. The tap gets the same prompt for every agent,
including ones with no hook system, without writing to any config file, and
the summary never leaves the machine.

The scoping is the privacy story. The tap exists from agent launch until a
prompt is accepted, the agent exits, 16 KB has passed, or fifteen minutes
have, and the manager detaches it the moment any of those happen. Nothing is
kept but the one line. Prompt history (⌘Y) doesn't change that: it reads the
history each agent already keeps of what was typed to it (Claude Code's and
Codex's `history.jsonl`, Pi's conversations), only while the panel is open,
and writes nothing of its own (`PromptHistory`). Three more rules: a title from the prompt is held for
eight seconds so an agent that titles itself wins outright rather than the
row renaming twice; an agent that was already running before this launch (a
keeper reattach) is not listened to, since its next line is a follow-up; and a
resumed conversation (`--continue`, `resume`) may replace a placeholder or a
screen guess but never a name that was right.

**Where a name came from decides who may replace it.** `Session.NameSource`,
in precedence order:

| Source | Set by | Replaced by |
|---|---|---|
| `placeholder` | the directory at creation ("Home" for the home folder); the agent's command ("Claude") for an agent in a folder of its own (`ChatFolder`) and for a worktree session started with a known agent; the branch for any other worktree session | anything |
| `model` | the on-device model, from the screen (`SessionNameGenerator`) | prompt, agent, user, or a better model guess |
| `prompt` | the first prompt typed into the agent, titled by the model | a new conversation's prompt, an agent title, or the user |
| `agent` | the agent's terminal title | a new agent title, or the user |
| `user` | an inline rename, or `wortel rename` | the user only |

So the model's screen guess only fills in where nothing better has spoken (a
plain shell running a long build), a prompt title beats that guess, an agent
title beats the prompt title, and a user rename is final. Nothing
periodically renames an agent session: its name changes only when a new
conversation starts.

**A worktree session is named for its task and shows its branch underneath.**
The branch is where the work lives, not what the work is. A session started
with a known agent (`AgentCommands.agent(in:)`) starts out called for the agent
("Claude", a placeholder) with its branch already on a second line, the same
glyph as the toolbar's branch chip, from the moment the row appears, while git
is still preparing the worktree. When the agent's title arrives only the words
change: named for its branch, the row was one line and grew a second under the
pointer a few seconds in. A worktree session with no agent (a plain shell, a
`wortel new --worktree -- npm run dev`) has no title coming, so it is called
after its branch, one line, until the model or a rename gives it a real name.
The row is two lines tall only in that state (`Session.showsBranchLine`), which is why the sidebar's identity
snapshot carries the set of tall rows: height is the one visual fact the
hosted SwiftUI row can't change on its own. Sessions persisted before the
branch was recorded ask git for it once at restore.

**The branch follows the name, once.** A worktree made without a branch name
(⌥⇧⌘N, `wortel new --worktree`) starts on a placeholder, `worktree/brave-river-1a2f`.
When the session gets a real name from any source but a placeholder ("Claude"
is no name for a branch), the branch is renamed for it (`fix-login-redirect`),
but only while nobody else can know the old one:
Wortel made it, it was never pushed, and it's checked out in that worktree
alone (`GitWorktree.mayRename`). The worktree's folder keeps its name, since
agents keep their history by directory. After that the branch is no longer a
placeholder, so later names leave it alone.

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

## Not done, on purpose

Codex and opencode generate their own titles and keep them in a database
(Codex: `~/.codex/state_5.sqlite`, `threads.title`), so a row could match
their resume pickers the way Claude rows match Claude's. That is a reader per
agent, and it is only worth writing for an agent that is actually in the
terminal. Pi's `/name` reaches the terminal title as `pi - <name> - <dir>`,
with no leading glyph, and is likewise not parsed yet. Neither is needed for
the row to have a good name; both would make it the agent's own.
