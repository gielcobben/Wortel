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

**Memory is per surface, and the script measures YOUR sessions.json.** Every
restored session is a live renderer with its own glyph atlas, so the number
tracks the session count and is not comparable between two machines, or between
two runs on one machine if the count changed. `measure.sh` prints the count it
measured for exactly this reason: 205 MB under a label claiming one session
sends you hunting a leak that is three terminals.

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
because two runs minutes apart differ by more than most changes do. On
2026-11-19 (Debug, a 120 Hz built-in display, the screen unlocked): 5.2 ms a
step with the column shut, 5.4 ms with it open, 4.9 ms on the divider, and 1
to 5 steps in 100 over 8.3 ms. That morning the three were 7.4, 10.4 and
12.7 ms, with up to 9 steps in 10 over. `--panes`: a pane sliding open or
shut has 1 or 2 turns of the run loop over 8.3 ms, where it had 7 to 15.
Numbers taken behind a lock screen come out about a fifth lower; don't
compare across the two.

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
