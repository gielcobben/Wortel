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

- **The group is a safe kill target.** `kill(-15614, …)` reaches that job and
  provably nothing else, because the agent and the shell are not in it. A subtree
  walk would have to reach the same answer by being careful, and being careless
  kills someone's agent mid-turn.
- **A group outlives its leader.** The orphan's five processes still shared pgid
  38931 four days after 38931 itself died. Orphans therefore need no separate
  handling: they are groups with nothing above them.

Within a session's tree, every distinct pgid is a row, minus two: the session
shell's own, and the agent's. The agent still gets a row, dimmed and not
killable, because it was 409 MB of that 1.39 GB and a total that hid it would not
match the rows above it.

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
buries the `:3000` someone typed into a browser. The row shows the lowest
non-inspector port; the rest are in the tooltip.

## Orphans

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
| `Wortel/Processes/ProcessMonitor.swift` | Cadence, the published snapshot, and the kill. |
| `Wortel/UI/RunningJobsPopover.swift` | The toolbar popover. |

The split exists so `RunningJobs` can be handed a fixture: the syscall layer is
untestable by construction, and everything that can silently be wrong lives next
door. `AgentLiveness` reads the same table rather than keeping a second one.

## Cost

A full scan of 605 processes shapes in about **1 ms**, and a 14-process tree with
argv, ports and footprint for every member measured 2.8 ms. It runs off the main
thread every 10 seconds with a quarter-interval tolerance so the OS can coalesce
it, and synchronously in exactly one place: the close sheet, where a dialog that
appears and then changes its mind would be worse than the millisecond.

## Known limits

- **Docker.** `docker compose up` puts its memory in the VM, not in any
  descendant, so a session running Docker reports near zero for the heaviest
  thing on the machine. Better to say nothing than something false.
- **The no-keeper fallback.** When the keeper is unavailable libghostty spawns
  the shell itself and never reports the pid, so those sessions have no tree to
  walk and degrade to orphan scanning only. Fixing it means touching shell
  integration, which the cwd finding otherwise made unnecessary.
- **`setsid`.** A process that leaves its session entirely is only findable as an
  orphan, which is the correct outcome but means it is never attributed to the
  session that started it while that session is still open.
