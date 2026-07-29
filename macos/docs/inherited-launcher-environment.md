# The environment Wortel inherits from whatever launched it

Why `InheritedEnvironment` exists, and the evidence behind it. Diagnosed
2026-07-29 against a live poisoned app; the marker names below are Claude Code
2.1.220's — versions move, re-verify before relying on details.

## The symptom

A Claude Code session started in a Wortel terminal printed:

```
⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker ·
  restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=…
```

and wrote no `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl` at all. So no
history, no `--resume`, and nothing for `AgentResumeStore` to bring back after a
relaunch — the resume feature silently loses its input.

## The cause

`/Applications/Wortel.app` was running with an *agent session's* environment
baked in. Read straight off the live app:

```sh
ps eww -p $(pgrep -x Wortel) | tr ' ' '\n' | grep -E '^(CLAUDE|GHOSTTY|NODE_OPTIONS)'
```

```
CLAUDE_CODE_CHILD_SESSION=1
CLAUDE_CODE_SESSION_ID=54c34306-9695-4300-9f03-bb161eb13de4
CLAUDE_CODE_EXECPATH=/Users/giel/.local/share/claude/versions/2.1.220
CLAUDECODE=1
CLAUDE_PID=95075                      # a process that had already exited
GHOSTTY_RESOURCES_DIR=/Applications/<other terminal>.app/Contents/Resources/ghostty
NODE_OPTIONS=--require=/var/folders/…/T/…-node-options/restore-node-options.cjs
```

How it got there — and it is not an accident, it's the normal development loop:

1. `scripts/release.sh` ends with `open /Applications/Wortel.app`.
2. That script runs from a coding agent's tool shell, which exports the markers
   above for its own children.
3. launchd reparents the app (`ppid 1`), so the variables **outlive the session
   that set them** — `CLAUDE_PID` pointed at a dead process.
4. libghostty spawns each surface's shell from the app's environment;
   `ghostty_surface_config_s.env_vars` can only *add* (see
   `GhosttyRuntime.newSurface`), so there is no per-surface place to remove them.

Every terminal Wortel opened therefore handed the next agent a marker saying
"you are already running inside me".

Three failures followed, all silent:

- **No agent transcripts.** The reported bug.
- **Another host's resources beat our bundle.** The Zig core checks
  `GHOSTTY_RESOURCES_DIR` *before* it looks for the `terminfo/78/xterm-ghostty`
  sentinel (`src/os/resourcesdir.zig`), so Wortel loaded a different terminal's
  shell integration and terminfo — while being deliberately bundle-only.
- **A dead session's private files stayed on our path.** Per-session CLI shims in
  the temp directory shadowed the real `claude`, and the `NODE_OPTIONS`
  `--require` would break every `node` we launch the moment that temp directory
  is swept.

## The fix

`Wortel/InheritedEnvironment.swift`, called from `main.swift` before
`NSApplication` exists — i.e. before any surface shell or `GitService` subprocess
can inherit anything. It removes:

- agent session identity: `CLAUDE_CODE_*` (by prefix, so a future marker is
  covered without a Wortel release), plus `CLAUDECODE`, `CLAUDE_PID`, `AI_AGENT`
- `GHOSTTY_*` — ours is set per-surface by libghostty at spawn; an inherited copy
  describes someone else's bundle and surface
- any variable whose *value* points inside the per-user temp directory — a file
  belonging to the launching session, not to us

`PATH` is filtered entry-by-entry instead of dropped, and never handed back
empty.

Two deliberate non-targets: **preferences** (`CLAUDE_EFFORT` says how the user
wants an agent to behave, not that one is running) and `TMPDIR` (its value *is*
the temp directory — the "points *inside*" test is what stops it deleting
itself; there is a test for exactly that).

Why removal is safe at all: each surface spawns a **login** shell, which
re-exports everything the user actually configured. What's scrubbed can only ever
be a leftover of the process that launched us.

## Verification

`WortelTests/InheritedEnvironmentTests.swift` pins both directions against the
real captured environment above — what must go, and what must survive. The whole
suite: 173 tests, 0 failures.

End to end, the real `scrub`/`apply` run against a genuinely poisoned shell
removed `AI_AGENT CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT
CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID CLAUDE_PID GHOSTTY_BIN_DIR
GHOSTTY_RESOURCES_DIR GHOSTTY_SHELL_FEATURES GHOSTTY_SURFACE_ID NODE_OPTIONS`
plus both temp shim directories from `PATH`, and left `TMPDIR`, `HOME` and
`CLAUDE_EFFORT` untouched.

## If you see it again

The scrub is self-healing from the next launch on, but an app **already running**
with a poisoned environment stays poisoned — a running process's environment
can't be changed from outside. Rebuild, then quit and reopen (the release
script's `open` only activates an instance that's already up):

```sh
cd macos && ./scripts/release.sh   # installs to /Applications
# then ⌘Q Wortel and launch it again
```

To confirm from a fresh session in a Wortel terminal:

```sh
env | grep -c CLAUDE_CODE_CHILD_SESSION     # 0
ls ~/.claude/projects/$(pwd | sed 's/[^a-zA-Z0-9]/-/g')/ | tail -1
```

The second command should show a `.jsonl` whose name is the current session id.
As a stopgap in a session that's already poisoned:
`env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE -u CLAUDE_PID claude`.
