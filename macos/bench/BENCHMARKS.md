# Wortel performance verification

Wortel embeds Ghostty's real engine (GhosttyKit): the VT parser, Metal
renderer, glyph atlas, and per-surface IO threads are all Ghostty's. So raw
terminal throughput / render / latency are inherently Ghostty-class — the job
of these checks is to confirm **the app shell adds no overhead** and that
launch, switching, and memory are tight.

The bar: **indistinguishable from Ghostty.app**, faster to launch, instant switch.

## What's measured automatically

`./bench/measure.sh` — cold-launch time and memory footprint (Release build).

Current (Apple Silicon, Release):
- App bundle: **7.1 MB**
- Cold launch: **55-57 ms** to process-alive. The first run of a set reads
  70-90 ms because the page cache is cold; the steady figure is the one to
  watch.
- Memory: **~92 MB** at 1 session (Metal renderer + atlas included; comparable
  to Ghostty), **~205 MB** at 3.

**Memory is per surface.** Every restored session is a live renderer with its
own glyph atlas, so the number tracks the session count: 205 MB under a label
claiming one session sends you hunting a leak that is three terminals.
`measure.sh` prints the count it measured for that reason. It used to measure
your own sessions.json, which made the number incomparable between machines.

**It measures a throwaway copy, never your Wortel.** The Release build is
copied with its own bundle id and data folder, so the memory figure is a first
launch on an empty folder, and only the copy (and its keeper) is stopped
between runs. It used to `pkill -9` every running Wortel, the one running the
script included. Figures above were taken the old way (2026-08) and have not
been retaken.

Telemetry (`Wortel/Telemetry/`, see `docs/telemetry.md`) was measured both ways
on the same machine and the same day, because the promise it made was that it
would not touch this: 55-56 ms with reporting compiled in but disabled (a 0.0.0
dev build), 57 ms with it stamped to a real version and reporting for real.
Memory 205 vs 206 MB. Both differences are inside the noise of a method that
polls `pgrep` in a loop.

## Throughput (vs every terminal installed)

```
./bench/compare.sh          # → bench/results/report.md
```

One command: detects the installed terminals (Ghostty, kitty, Alacritty,
iTerm2, Apple Terminal — installing one adds it to the report), streams the
three fixtures through each sequentially, and writes a median table relative
to Wortel. Timing is DSR-synced (`timed_stream.py`): the clock stops when the
terminal answers `ESC[6n`, i.e. after it has *parsed* everything — `time cat`
stops when the pty buffer accepts the last write, which rewards buffer depth,
not speed.

Wortel has no CLI, so the script types into a fresh session (⌘N) via System
Events — grant Accessibility to the terminal running the script, or paste the
printed `runner.sh` command into Wortel by hand when prompted. Wortel is left
running afterwards; the other terminals are quit.

`./bench/gen.sh` (re)writes the fixtures to `bench/data/` (gitignored):
`scrolling.txt` (plain), `colors.txt` (24-bit truecolor), `cursor.txt`
(SGR churn). `compare.sh` runs it automatically when they're missing.

Accept: within noise of Ghostty.app.

## The keeper's terminal

Every byte now goes through the keeper, which parses it into its own terminal
and forwards it to the app (`docs/architecture/keeper.md`). Measured
2026-11-20 on Apple silicon, Release builds, against protocol 1 (the pty
passed to the app, nothing parsed in the keeper):

| | protocol 1 | keeper keeps the terminal |
| --- | --- | --- |
| `cat` of 64 MB in a shown session, end to end | 97 to 103 MB/s | 99 to 110 MB/s |
| CPU for those 64 MB | app 1.17 to 1.35 s | app 1.04 to 1.19 s, keeper 0.45 to 0.47 s |
| A keystroke's round trip (typed, echoed, back) | median 28 µs, p99 54 | median 42 µs, p99 85 |
| Keeper, 20 idle shells | | 9 MB |
| Keeper, 10 sessions with full 10 MB scrollbacks | | 108 MB, 23 MB after 40 s quiet |
| A dropped terminal shown again | | 30 to 45 ms |

The keeper parses in parallel with the app and stays ahead of it, so
throughput is the app's; what is added is the keeper's CPU, about 7 ms a MB.
The end-to-end figures were taken from copies launched in the background
(parsing, not drawing). How to take them again:

```sh
xcodebuild ... -scheme WortelTests -configuration Release test \
  -only-testing:WortelTests/KeeperTerminalThroughputTests   # prints THROUGHPUT and KEYSTROKE
```

Memory is `footprint` (phys_footprint), not RSS: on a Mac short of memory,
macOS compresses a quiet keeper's pages and RSS reads as a few MB.

## Render stress

Clone `github.com/const-void/DOOM-fire-zig`, run it in both terminals side by
side (needs Zig). Equal FPS/smoothness by eye; confirm with Instruments →
Core Animation FPS.

## Resizing

`./scripts/bench-resize.sh` (a Debug build, in a throwaway copy): the window
resized 480 times at 120 Hz, then with `--column` the divider beside the side
column. It prints what a step cost the main thread and how many steps took
longer than the 8.3 ms a frame lasts. `--compare` runs each round twice in
the same app, with libghostty's frame at every step and with Wortel's rule,
because two runs minutes apart differ by more than most changes do. **It
puts the copy's window in front of everything while a round runs**, and a
round the window was not on screen for at every step prints "NOT A
MEASUREMENT": a covered window is cheaper (SwiftUI lays nothing out for one
nobody can see), by a third with the side column open, and a day of figures
taken from behind other windows had to be thrown away. On 2026-11-19 (Debug,
a 120 Hz built-in display, the window on screen, a load of about 5): 4.5 ms a
step with the column shut, 5.2 ms with it open, 5.3 ms on the divider, with
libghostty's frame at every step 6.8, 6.9 and 7.3. `--panes`: a pane sliding
open or shut has about one turn of the run loop over 8.3 ms, where it had
10 to 15. A machine that is busy moves every figure: at a load of 20 they
double. Those figures are from while the side column was a pane of the
window's split view. Since the splits of 2026-11-26 (on `main`, not in a
release yet) it is a split of the window's tree. `ResizeBench` reads that tree now: the
divider round drags the divider on the side column's inner edge, and
`--panes` times the tree's own slide for the column. One thing reads
differently: sizes are shares, so the side column gives with the terminal at
every step of a window round, and the count of steps where the pane beside
the terminal changed width (`besideResized`), which was 0 of 480 while it
kept its width, is now every step. No figures were taken since.

`./scripts/try-switch.sh` is the same idea for a session switch: 72 returns
to a session with the side column open, at six paces, and where its terminal
was after each. Every one should be where it started.

## Typing latency

[Typometer](https://pavelfatin.com/typometer/): run ≥5 passes in Wortel and in
Ghostty.app, same display, same font size. Distributions should overlap. This
is the metric a native shell can actually win — keep the responder path direct
(SurfaceView is first responder, no event monitors between NSEvent and
`ghostty_surface_key`).

## Cold launch (precise)

Instruments → **App Launch** template on the Release build, 10 cold runs
(after `sudo purge` for worst case). Compare time-to-first-frame with
Ghostty.app.

## Session-switch soak

20 sessions (⌘N ×20), then alternate ⌘1/⌘2 rapidly for a few hundred switches.
Expect: zero flash (last frame persists in the IOSurface layer), keystrokes
land instantly after each switch, memory flat afterward. Profile `show()` with
Instruments → Core Animation (one commit per switch, no layout storm).

## Memory / leak check

`footprint <pid>` at 1 / 10 / 20 sessions. Open+close 50 sessions (⌘N/⌘W) →
footprint should return to baseline (surface freed in `SurfaceView.close()`).
