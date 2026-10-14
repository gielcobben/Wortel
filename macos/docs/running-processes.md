# Running processes

How Wortel knows what each session is still running, what it costs, and what it
is serving.

## Why

An agent session reported the machine was low on memory "because of all these
running servers". Nothing on the machine can answer that, because nothing else
knows *which terminal session started what*. Wortel does: the keeper forks every
session's shell, so each session is the root of a process tree.

Measured on a real machine while building this, one session held **1.39 GB**:

```
zsh [37499]                                  <- the session shell
  claude [37616]               408.7 MB
    bun dev:web  …
      node [15618]             572.0 MB  :3000 :9231
        workerd [15623]        133.4 MB
    bun dev:images  …
      node [15636]             160.9 MB
        workerd [15638]         52.9 MB  :3002 :9233
```

And, parented to `launchd` and invisible to everything including Activity
Monitor's session column, a **four-day-old** orphan holding 385 MB and seven
ports, from a session that had closed days earlier. Filtering the ephemeral ports
it held no reachable port at all: it was not serving anything.

## A job is a process group

Not a subtree. This is a measured fact about how shells work, not a heuristic: an
interactive shell puts each job it starts into its own process group, and so does
every `zsh -c` an agent spawns for its shell tool. In the tree above, `zsh -c`
(15614) led `bun → bun → node → workerd`, all at pgid 15614, while the agent sat
alone at 37616 and the session's own shell at 37499.

Two things follow, and both are why this is the model rather than a tree walk:

- **The group is usually a safe kill target.** `kill(-15614, …)` reaches that job
  and, when the group holds one job, provably nothing else, because the agent and
  the shell are not in it. "Usually" is doing real work in that sentence: see
  *A group is not always one job* below.
- **A group outlives its leader.** The orphan's five processes still shared pgid
  38931 four days after 38931 itself died. Orphans therefore need no separate
  handling: they are groups with nothing above them.

Within a session's tree, every distinct pgid is at least one row, minus two
groups: the session shell's own, and the agent's. The agent still gets a row,
dimmed and not killable, because it was 409 MB of that 1.39 GB and a total that
hid it would not match the rows above it.

## The numbers

**Footprint is `ri_phys_footprint`, never RSS.** On a machine under pressure the
two diverge wildly, because compressed and swapped pages leave the resident set.
`ps` reported the live vite above at 30 MB; its footprint was 572 MB, a 19x gap.
Reporting RSS is exactly why "where did my memory go" is invisible to every tool
you would otherwise reach for.

**Labels come from argv, never `p_comm`.** The process names in that tree were
`2.1.267` (claude renames itself to its version), `bun`, `bun`, `node`, `node`,
`workerd`. The group's leader is `zsh -c source ~/.claude/shell-snapshots/…`,
which describes nothing, so the label looks past shell wrappers to the first real
program. A runtime is dropped when the next token is a path (`node …/bin/vite
dev` is `vite dev`) but kept when it is not (`bun dev:web` stays whole, because
`dev:web` names nothing). `p_comm` is the last resort, used only so a process
whose argv cannot be read still gets a row rather than vanishing.

**Ports are filtered hard.** That two-server session held fifteen listening ports;
eleven were ephemeral (≥ 49152) or a node inspector (9229-9249). Showing them
buries the `:3000` someone typed into a browser. The row shows every port it
holds that survives that filter, up to three so a name cannot be pushed off the
row; the rest are in the tooltip.

## A job belongs to its session

A server started in a session is that session's for its whole life, and closing
the session stops it. There is no mode in which the two drift apart on purpose.

This had to be made true rather than assumed. Closing a session hangs up its
shell, and a hang-up is advisory: `nohup`, `disown`, and any dev server that
daemonises itself shrug it off, get reparented to launchd, and keep holding
`:3000` with nothing on screen to say so. That is exactly how the four-day-old
orphan above came to exist. The close sheet was already saying "Closing stops
…", which was a promise nothing kept.

Two pieces keep it:

- **Ownership is sticky.** Ancestry answers "whose is this" only while the
  process is still under the shell, and it forgets at the exact moment the
  answer starts to matter. So every scan records each work process against its
  session (`RunningJobs.recordingOwners`), keyed by pid *and start time*, since
  a recycled pid is somebody else's process. A group that has left every shell
  but holds a recorded process is claimed for its session and marked
  `detached`. If that session is already gone it is an orphan that says whose it
  was (`lastSessionID`), and skips the project-directory guesswork below, because
  it is not a guess. The map is saved to `process-owners.json` beside `project-roots.json`
  (`ProcessOwnersStore`) whenever it changes, because the keeper keeps shells, and
  so their detached servers, alive across a relaunch, and without the record a
  quit made strangers of them. Its start times are stored as seconds since the
  reference date, `Date`'s own representation: seconds since 1970 do not survive
  the round trip exactly, and a record a hair off matches nothing, silently.
- **Closing stops the work.** `SessionManager.close` asks
  `ProcessMonitor.stopWork(of:)` before it hangs up the shell. That scans fresh
  (the last snapshot can be ten seconds old and miss the server started just
  before ⌘W) and sends each job the same SIGTERM-then-SIGKILL as Quit. Agents are
  not in it: the agent is the session, and its hang-up is the shell's. A session
  closing is not counted as `process_quit`, which measures people choosing to.

The close sheet also asks when the terminal itself sees nothing running. Ghostty
only knows the foreground process, so a shell at its prompt with `bun dev &`
behind it used to close without a word.

## A server inside the agent's own group

An agent's shell tool usually starts a command in a new process group, and that
is what makes the group model work: Claude Code's `zsh -c`, Pi's bash tool,
opencode, amp and cursor-agent all `setsid`. Three do not. **goose** runs
`bash -c` with no new group at all, **Kimi** and **Factory droid**'s foreground
tool do the same, and a Pi extension that reaches for `pi.exec` instead of the
bash tool inherits Pi's group too. Every stdio MCP server is in there as well.

Measured on a real machine, `pi` (19665) led a group holding
`chrome-devtools-mcp`, `pnpm run preview` and the vite under it serving `:5188`,
all pgid 19665. The group contained the agent, the agent is never work, and so
the server the session was running was not in the pill, the popover, or what
closing the session would stop.

So the agent's group is split: a child of the agent whose tree holds a listening
port is its own job. **Only one holding a port**, because the agent's other
children are its scaffolding — an MCP server over stdio is not something to
offer a Quit button on, and stopping one breaks the agent mid-turn. The split
job never owns the group (the group is the agent's), so stopping it signals its
own processes and never `-pgid`.

## A server that left before any scan saw it

The shape agents reach for most is `nohup pnpm dev > log 2>&1 &` in a shell tool
that returns as soon as the line does. The `sh -c` exits in milliseconds, the
server is adopted by launchd, and neither ancestry nor the ownership map ever
saw it under the session. People type the same thing (`( npm run dev & )`), and
a server that daemonises itself does it without being asked.

Two links survive that, and neither is a guess:

- **The environment.** Every session's shell is started with
  `WORTEL_SESSION_ID`, and whatever it runs inherits it through any number of
  forks, `setsid`s and `nohup`s. `KERN_PROCARGS2` returns the environment a
  process was `exec`ed with, so it cannot be edited away either. The kernel
  withholds it for Apple's platform binaries, and returns it for node, bun, deno
  and a Homebrew, uv or nix python — which is what serves a port.
- **The terminal session.** `getsid` changes only when something calls `setsid`,
  so `( … & )` and `nohup … &` keep the session their shell had, and the kernel
  answers for every process including Apple's own. This is what finds
  `/usr/bin/python3 -m http.server`, whose environment is withheld.

**A port is what qualifies a group here, and that is the whole test.** A tag
says where a process was started, not that it is a job: `code .` from a session
starts an editor carrying the same variable and the same terminal session, and a
Quit button on somebody's editor would be worse than the bug. Bundles are not
excluded, because an Electron or Tauri dev build *is* an `.app` (in
`node_modules`, or `target/debug`) and Apple's python lives inside
`Xcode.app/…/Python.app`: the rule that hid an editor hid those too.

Each process's tag is read once and kept by pid and start time
(`SessionTagCache`), so the steady state costs nothing and a recycled pid is
read afresh.

## Orphans

Since the above, an orphan is the fallback, not the normal way a server is found:
something from before this existed, a `setsid`, a session on the no-keeper path,
or a server that left its shell and whose session closed before any scan saw it.
The pill and popover are about one session, so an orphan no session owns is not
listed there; one whose session is known is listed under it as detached.

A process group with no live session above it, whose working directory sits
inside a project Wortel has opened a session in.

`proc_pidinfo(PROC_PIDVNODEPATHINFO)` still answered for the four-day-old orphan,
which is what makes attribution free: **no marker has to be written at spawn
time**, so the shell integration (three copies, one of them untestable here) is
left alone entirely.

The project-directory test is load-bearing and not a nicety. **338 processes had
`ppid == 1` under one uid** on an ordinary Mac; without it the list is every login
agent and XPC service on the system. `ProjectRoots` remembers those directories
across launches, because the orphan worth finding is precisely the one whose
session closed days ago. It refuses home and anything above it: a session opened
at `~` is ordinary, and remembering that as a project would match everything.

## Opening one

A row holding a port is a link: clicking it opens `http://localhost:<port>`,
and a right-click carries Open in Browser, Copy Address, Reveal in Finder and
Quit.

**`localhost`, never `127.0.0.1`.** Node tooling commonly binds the IPv6
loopback only. Measured on the machine this was built against:

```
node [::1]:3000          <- vite, IPv6 only
http://127.0.0.1:3000    <- connection refused
http://localhost:3000    <- 200
```

A browser gets away with `localhost` because it resolves to both families and
tries each. A v4 literal would have broken the single most common case.

**No attempt is made to decide whether it is a web server.** Probing answers the
wrong question, and the measurements say so plainly: the node inspector answers
HTTP and is useless to open, while a real vite returned *nothing* to a `HEAD`
and a workerd returned 400. A list of known web tools goes stale instead. So
every port is offered, and the cost of guessing wrong is a browser tab that does
not load, which is cheap and obvious, unlike a wrong Quit.

Copy Address is what carries the rows this cannot classify. A database, a gRPC
server or a broker is not something to open, but `localhost:6379` is exactly
what its client wants, which is why the address is host and port with no scheme.

## A session's own ports

Seeing the ports is half of it; the other half is two worktrees not fighting
over one. A worktree isolates files, not the machine: two agents each running
`npm run dev` in their own checkout still both want :3000, and the second either
fails or quietly moves somewhere nobody looks.

So every session gets **ten ports of its own**, and its shells get the first as
`WORTEL_PORT` (`PortBlock`, `Wortel/Sessions/PortBlock.swift`):

```sh
npm run dev -- --port $WORTEL_PORT
python -m http.server $((WORTEL_PORT + 1))
```

- **From 20000 to 29999, in blocks of ten**, above the usual dev-server and
  database ports and below the ephemeral range macOS hands out. Blocks holding a
  well-known port in that range (Redis Sentinel, MongoDB, Minecraft, Synergy)
  are never handed out.
- **Chosen once, kept for good.** The search starts at a block derived from the
  session's id and walks forward past blocks another session holds or anything
  on the machine is listening on (a `bind` on IPv4 and IPv6, which sees every
  user's listeners). The result goes into `sessions.json`, and is never
  re-checked: after a relaunch the session's own server is usually the thing
  listening there.
- **Side terminals share the session's block.** A terminal beside an agent is
  for what the agent is working on.
- **`CONDUCTOR_PORT` carries the same value.** Conductor reserves the same
  "first of ten" per workspace, so a repository whose scripts already say
  `--port $CONDUCTOR_PORT` runs here unchanged. An inherited `CONDUCTOR_*` is
  scrubbed at launch (`InheritedEnvironment`), or the exec fallback, which can
  only add variables, would hand every session the launching workspace's ports.
- **`PORT` is deliberately left alone.** Next, Express, Rails and Vite read it,
  and setting it would move every dev server in every session off the port its
  README names.

A shell the keeper kept across the update that brought this has no `WORTEL_PORT`
until it is restarted; its session has a block all the same, and side terminals
opened from then on get it.

## Quitting

SIGTERM to `-pgid`, then SIGKILL after three seconds. SIGTERM rather than the
SIGHUP `PtyHost` uses, because this is a program being asked to shut down rather
than a shell losing its terminal, and a dev server that traps SIGTERM to clean up
should get to.

The escalation does **not** re-signal `-pgid`. By then that group number may
belong to something else, and `kill(-pgid, SIGKILL)` would take it out. It kills
the individual processes it originally asked to stop, and only those still in the
same group.

The agent and the session shell are never killable, at any layer.

## Where the code is

| File | Role |
| --- | --- |
| `Wortel/Processes/ProcessTable.swift` | The syscalls, and nothing else. `sysctl` for the table, `KERN_PROCARGS2` for argv, `proc_pid_rusage` for footprint, `proc_pidfdinfo` for LISTEN ports, `PROC_PIDVNODEPATHINFO` for cwd. |
| `Wortel/Processes/RunningJobs.swift` | All the decisions: grouping, labelling, port filtering, orphan classification, the close-sheet copy. Pure, and pinned by `RunningJobsTests`. |
| `Wortel/Processes/ProjectRoots.swift` | Which directories are specific enough to attribute an orphan to. |
| `Wortel/Processes/ProcessOwnersStore.swift` | Which session started which process, on disk, so a detached server is still its session's after a relaunch. |
| `scripts/verify-running-jobs.py` | The live check: real servers, in a real login shell, in every shape agents and people start them in, scanned by this code. |
| `Wortel/Processes/ProcessMonitor.swift` | Cadence, the published snapshot, the ownership map, and the kill. |
| `Wortel/UI/TitleBars.swift` | `RunningButton`, in the main area's titlebar row and about the selected session only: a dot (green while something serves), and the popover's list behind it, from `RunningJobsSnapshot.status`. |
| `Wortel/UI/RunningJobsPopover.swift` | The popover: that session's jobs as one flat list, hover Copy and Stop per row. |

The split exists so `RunningJobs` can be handed a fixture: the syscall layer is
untestable by construction, and everything that can silently be wrong lives next
door. `AgentLiveness` reads the same table rather than keeping a second one.

## Cost

Measured on a machine with 693 processes, 7 sessions and 6 remembered project
roots. The raw syscalls are cheap: the whole table is 0.2 ms, and doing *every*
read for *every* process comes to about 6 ms (argv 4.2, ports 0.9, cwd 0.5,
footprint 0.4).

A full scan is **6.9 ms**, down from 15.9 ms. It was slower than reading
everything about everything, which is the shape of a scan doing work twice:

- **Orphan candidates were shaped before being filtered.** A job is built by
  reading argv for every process in it, and nearly every candidate is then
  thrown away for sitting outside any known project. The directory decides, it
  is one cheap syscall, and it is asked first now.
- **Descendancy was recomputed per session.** The membership test walked each
  candidate's parent chain once per session; with nine sessions and eight
  hundred processes that was most of the scan. The set of pids under any session
  is worked out once.
- **Arguments were read twice per process**, once to classify the agent and once
  to label. Memoised for the span of a scan, which is the only window over which
  a pid's arguments cannot change.

It runs off the main thread every 10 seconds with a quarter-interval tolerance so
the OS can coalesce it, and synchronously in exactly one place: the close sheet,
where a dialog that appears and then changes its mind would be worse than the
milliseconds.

## An agent is recognised by its program, not by a path

An agent's group is hidden, so anything mistaken for an agent disappears. The
name is matched against `p_comm` and against the executable, `argv[0]` and
`argv[1]` — but within those, only where a program's *name* lives: the file
itself (`claude`, `…/bin/aider`, `aider.py`) or its installed package
(`node_modules/@earendil-works/pi-coding-agent/dist/cli.js`,
`@google/gemini-cli/dist/index.js`).

Matching any path component instead made `/Users/x/claude-demo/server.js` Claude
Code and `pi-site/node_modules/.bin/vite` Pi. A project named after the agent
you use with it is not a rare thing to have.

Packagers decorate the name, and the decoration is not a different program:
nixpkgs' `wrapProgram` leaves `.pi-wrapped`, and a Bun-compiled binary carries
`.exe` on macOS too (`amp.exe`). Both are stripped before matching.

`RunningJobs.unresumableAgents` carries the agents Wortel cannot resume but must
still recognise — Kimi, Qwen, droid and Copilot. Recognition and resume are
different questions, and confusing them is expensive here: Kimi and droid run a
tool's command in their own process group, so an unrecognised one is not a
hidden agent, it is a killable row whose Quit ends the user's conversation.

## Checking it against a real machine

`RunningJobsTests` pins the shaping against fixtures. It cannot tell you that
the shapes are the ones that happen, and every bug this feature has shipped was
of that kind: a server nobody had a fixture for, found by the person running it.

`./scripts/verify-running-jobs.py` starts real servers in a real login shell —
`/usr/bin/login` and the bash trampoline, the way the keeper does it — and asks
this code what it sees. 44 shapes: typed at the prompt, `&`, `nohup`, a
subshell daemon, a double fork, an Apple platform binary, and for three kinds of
agent every spawn shape found in their source (same group, `setsid`, a pty, a
subshell wrapper, a worker in between, and each of those backgrounding with
`&`). It also checks that a project named `claude-demo` or `pi-site` is not
mistaken for an agent.

It compiles `ProcessTable` + `RunningJobs` into a small command, so what runs is
the shipping code rather than a copy of it. Run it before releasing anything
that touches this.

## A group is not always one job

`bun dev` fanning out to `dev:web` and `dev:images` puts both trees in one
process group, holding `:3000` and `:3002` between them. Reported as one job it
read as `bun dev:web` with the pair's combined memory, the lower port, and
nothing to say the other existed, and its Quit would have stopped both.

So a group is split by tree: any member whose parent sits outside the group
starts a job, and its descendants belong to it. Identity is that root process,
because `pgid` is no longer unique, and everything keyed on the group has to
follow: the hover highlight and the optimistic row removal both acted on two
rows until they did. A job that is the whole of its group still gets
`kill(-pgid, …)`; one sharing a group signals its own processes.

## Known limits

- **Docker.** `docker compose up` puts its memory in the VM, not in any
  descendant, so a session running Docker reports near zero for the heaviest
  thing on the machine. Better to say nothing than something false.
- **The no-keeper fallback.** When the keeper is unavailable libghostty spawns
  the shell itself and never reports the pid, so those sessions have no tree to
  walk and degrade to orphan scanning only. Fixing it means touching shell
  integration, which the cwd finding otherwise made unnecessary.
- **Work with no port that leaves before a scan.** A detached process is
  claimed by its environment or its terminal session only when it holds a port,
  because that is the only thing that distinguishes a server from an editor
  somebody launched from the same shell. A `nohup npm run build:watch &` that
  serves nothing, started and detached inside one scan interval, is therefore
  only findable as an orphan.
- **A process that sheds both links.** `setsid` plus `env -i`, or anything
  started by launchd on the session's behalf (`brew services`, a LaunchAgent),
  keeps no connection to the session at all and is an orphan by directory or
  nothing.
- **The ten-second window.** A server that leaves its shell and whose shell then
  exits on its own (`exit`, not ⌘W) inside one scan interval was never recorded,
  so it outlives the session as an orphan. ⌘W scans at the moment of closing
  and is not affected.
