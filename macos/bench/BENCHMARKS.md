# Wortel performance verification

Wortel embeds Ghostty's real engine (GhosttyKit): the VT parser, Metal
renderer, glyph atlas, and per-surface IO threads are all Ghostty's. So raw
terminal throughput / render / latency are inherently Ghostty-class — the job
of these checks is to confirm **the app shell adds no overhead** and that
launch, switching, and memory are tight.

The bar: **indistinguishable from Ghostty.app**, faster to launch, instant switch.

## What's measured automatically

`./bench/measure.sh` — cold-launch time and memory footprint (Release build).

Current (Apple Silicon, 1 session):
- App bundle: **7.1 MB**
- Memory: **~92 MB** (includes the Metal renderer + atlas; comparable to Ghostty)

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
