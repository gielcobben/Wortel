# Agent busy/attention signals

How Wortel knows a terminal agent is working (sidebar spinner) or wants you
(attention dot + Dock badge + notification). All agent behavior below was
verified against source or live byte captures on 2026-07-10; versions move,
re-verify before relying on details.

## Wortel's detection channels (SessionManager)

1. **OSC 9;4 progress (ConEmu)** — `9;4;3` (or any non-remove state) = busy;
   `9;4;0` after ≥2s of busy = "stopped working" → attention ~1s later unless
   progress resumes ("progress-quiesce"). This is the emerging cross-tool
   standard (Ghostty 1.2+, Windows Terminal, ConEmu; emitted by Claude Code,
   crush, cargo ≥1.87, systemd v257, mise, winget…).
2. **Title markers** — fallback for agents that only signal via the window
   title. Braille spinner prefix (U+2800–U+28FF; Claude Code, Codex, Amp) or
   `✦`/`⏲` (Gemini) = busy; marker disappearing = same quiesce path;
   `✋` prefix or "Action Required" (Gemini, Codex) = attention immediately.
3. **Desktop-notification escapes** — OSC 9 (non-progress payload), OSC 777,
   OSC 99 are parsed by the libghostty core and forwarded; Wortel relays them
   as attention + macOS notification. Emitted by Codex (default), crush
   (default), Amp (default), Gemini/opencode (opt-in), Pi's official notify
   extension.
4. **Bell** and **command-finished ≥10s while unselected** — classic paths for
   non-agent commands.
5. **Screen activity** (`AgentActivity`) — the fallback for agents that emit
   none of the above (opencode, goose, aider). A watched session's active screen
   is hashed once a second; a screen that keeps changing is an agent working, one
   that then holds still for 3s is a turn ending. It is the only *guessing* tier,
   so it is fenced in hard:
   - It never watches a session whose agent has already announced itself
     (`SessionManager.speaksForItself`) — proof lasts for that whole agent run,
     not for a timeout. An idle Claude Code session has no signals to show for
     the last hour and must not therefore look like a silent agent.
   - It never watches the session you're looking at, or one with no agent marker.
   - **Two changed samples within 5s** make a working agent; one does not. A
     terminal repaints for reasons that aren't the agent — a window/inspector
     resize re-wraps every session at once, and a focus report makes every agent
     TUI redraw when you ⌘-tab — and each of those is a single frame.
   - Those two events (`SurfaceView.onSizeChange`, app activate/resign, window
     occlusion) also re-baseline every tracker, so the repaint they cause is
     thrown away rather than counted.
   - `AgentPrompt.looksBlocked` decides how loud a turn-end is. "esc to
     interrupt" is a *working* marker and vetoes the blocked reading — it is not
     a prompt affordance, however much it looks like one.

Focus matters: Codex, crush, Amp, and Gemini only notify while the terminal
reports *unfocused* (DECSET 1004). Wortel reports per-surface focus =
first-responder **and** key window (`SurfaceView.updateFocus`), so switching
sessions, ⌘-tabbing away, or minimizing all propagate to the agent.

The bundled shell integration suppresses its synthetic per-command `9;4;3`
for known interactive programs (agents, editors, pagers, REPLs — see
`_ghostty_wortel_interactive` in the zsh/bash/fish integrations), because they
never return to the prompt; the agent's own signals take over.

## Per-agent status (out-of-the-box defaults, terminal = ghostty)

| Agent | Busy | Attention (needs you) |
|---|---|---|
| Claude Code | ✅ OSC 9;4 + braille title | ✅ quiesce on 9;4;0 (permission prompt + turn end) |
| Pi | ⚠️ off by default — enable `showTerminalProgress` (`/settings` → Terminal progress, or `~/.pi/agent/settings.json`) | ⚠️ same switch → quiesce at turn end; official `notify.ts` example extension adds OSC 777 |
| Codex | ✅ braille title spinner | ✅ OSC 9 notification (turn end + approvals, unfocused only) + "Action Required" title |
| Gemini CLI | ✅ `✦`/`⏲` title | ✅ `✋ Action Required` / `◇ Ready` title edges; opt-in `general.enableNotifications` adds OSC 777 |
| crush | ✅ OSC 9;4 (gated on ghostty XTVERSION) | ✅ OSC 99/777 (permission + turn end, unfocused only) |
| Amp | ✅ braille title spinner | ✅ OSC 777 ("Waiting for Approval" / "Agent is ready", unfocused only) |
| opencode | ❌ nothing (title has no marker) | ⚠️ opt-in `attention.enabled` → OSC 777 |
| aider | ❌ | ⚠️ opt-in `--notifications` (spawns terminal-notifier/osascript itself) |
| goose | ❌ | ❌ (static 🪿 title only) |

## Gotchas learned the hard way

- Claude Code's OSC 9;4 is gated on `TERM_PROGRAM=ghostty` — captures under
  `xterm-256color` show nothing. Its "auto" notification channel sends **no
  bell and no OSC 9/777** under Ghostty; the 9;4;0 edge is the only signal.
- Pi emits OSC 133;A/B/C zone marks around every message. The libghostty core
  synthesizes a `COMMAND_FINISHED` (small duration) from a mid-session `133;A`,
  which clears busy. Pi's 1s progress keepalive re-arms it; SessionManager
  treats a re-arm within 3s as a continuation of the same run so the ≥2s
  attention gate stays honest, and `COMMAND_FINISHED` deliberately does *not*
  cancel a pending quiesce raise.
- Ghostty's GTK apprt drops progress not refreshed within 15s ("bad actor"
  protection). Wortel must NOT copy that: Claude Code emits a single `9;4;3`
  per turn with no keepalive. Stuck-busy safety comes from `COMMAND_FINISHED`
  firing at the next shell prompt instead.
- macOS notification banners require a signed `/Applications` build
  (`./scripts/release.sh`); ad-hoc Debug builds only get the sidebar dot and
  Dock badge.
