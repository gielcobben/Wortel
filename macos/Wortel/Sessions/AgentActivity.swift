import Foundation

/// Deciding whether an agent CLI is working or waiting, from the only thing
/// every agent produces: what it draws on screen.
///
/// The stream-based signals (OSC 9;4 progress, OSC 133 command marks, a
/// spinner in the title, a desktop notification) are precise, and where they
/// exist they stay authoritative — but most agents emit none of them. For those
/// Wortel used to be structurally silent: the shell integration deliberately
/// skips the synthetic busy spinner for long-lived interactive programs, so a
/// silent agent produced no busy state, therefore no quiesce, therefore no
/// notification, ever.
///
/// This fills that hole without learning anything about individual agents. A
/// screen that keeps changing is an agent that keeps working; a screen that
/// holds still is an agent waiting on you. That single rule covers every agent,
/// including ones that don't exist yet — which is the part per-agent screen
/// pattern lists can't do, and why they need an out-of-band update channel to
/// stay current.
///
/// Two decisions keep the false-positive rate down, and both matter more than
/// the detection itself, because a terminal that cries wolf gets muted:
///
/// - It only runs on sessions you are **not** looking at, and only on ones whose
///   agent has never announced itself. The one you're watching needs no
///   notification, and your own typing changes the screen — which would
///   otherwise read as the agent working.
/// - A change is only evidence *after* a grace window, so an agent's noisy
///   startup, and the repaint that happens the moment you switch away, are not
///   mistaken for work.
/// - **One change is never enough.** A terminal repaints for reasons that have
///   nothing to do with the agent: the window or the inspector resizing re-wraps
///   every session at once, and a focus report (DECSET 1004) makes every agent
///   TUI redraw the moment you ⌘-tab. Each of those is a single frame of
///   difference on an otherwise frozen screen, and treating it as work is how an
///   agent that has been idle for days ends up announcing a finished turn. Work
///   has to keep moving to count.
enum AgentActivity {
    /// How often a watched session's screen is sampled.
    static let sampleInterval: TimeInterval = 1.0
    /// Changes within this long of the agent appearing (or of the session
    /// becoming unwatched) are baseline, not evidence.
    static let graceWindow: TimeInterval = 2.0
    /// A screen that has held still this long means the agent stopped working.
    /// Long enough to ride out an agent that pauses mid-render, short enough
    /// that a finished turn is still news.
    static let quietAfter: TimeInterval = 3.0
    /// How many changed samples make a working agent, rather than a one-off
    /// repaint (see the note above). Two, because the cheapest way to tell a
    /// reflow from an agent is that the reflow happens once.
    static let changesForWork = 2
    /// How long those changes have to arrive within. Wide enough for an agent
    /// that prints a line every few seconds, short enough that two unrelated
    /// repaints minutes apart never add up to a turn.
    static let evidenceWindow: TimeInterval = 5.0
}

/// What a sample says just happened. Edge-triggered on purpose: the session
/// machinery treats "went quiet" as the start of a settle timer, so repeating
/// it every second would postpone the notification forever.
enum AgentActivityEvent: Equatable {
    case startedWorking
    case wentQuiet
}

/// Per-session sampling state. A value type with no dependencies so it can be
/// tested against a synthetic clock rather than by watching a real agent.
struct AgentActivityTracker: Equatable {
    private var digest: UInt64?
    private var lastChange: Date
    private var working = false
    /// Samples before this are baseline only.
    private let graceUntil: Date
    /// Changes counted toward the current evidence window, and when that window
    /// opened. A lone repaint expires instead of accumulating.
    private var changes = 0
    private var changesSince: Date?

    init(now: Date, grace: TimeInterval = AgentActivity.graceWindow) {
        lastChange = now
        graceUntil = now.addingTimeInterval(grace)
    }

    /// Feed one screen digest. Returns an event only on a transition.
    mutating func sample(digest incoming: UInt64, now: Date) -> AgentActivityEvent? {
        defer { digest = incoming }

        guard let previous = digest else {
            // First sight of this screen is the baseline, never evidence.
            lastChange = now
            return nil
        }

        if incoming != previous {
            lastChange = now
            // A change during the grace window re-baselines instead of
            // counting: an agent painting its banner is not doing your work.
            guard now >= graceUntil, !working else {
                changes = 0
                changesSince = nil
                return nil
            }
            // Evidence accumulates only while it keeps arriving: a change that
            // lands outside the window opens a new one instead of joining the
            // last, so two repaints an hour apart never add up to a turn.
            if let since = changesSince, now.timeIntervalSince(since) <= AgentActivity.evidenceWindow {
                changes += 1
            } else {
                changesSince = now
                changes = 1
            }
            guard changes >= AgentActivity.changesForWork else { return nil }
            changes = 0
            changesSince = nil
            working = true
            return .startedWorking
        }

        guard working, now.timeIntervalSince(lastChange) >= AgentActivity.quietAfter else {
            return nil
        }
        working = false
        return .wentQuiet
    }
}

/// FNV-1a over the raw screen bytes. Chosen so a sample costs one pass and no
/// allocation — the text never becomes a Swift String unless the screen
/// actually went quiet and something is about to be decided from it.
func agentScreenDigest(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 0x1000_0193
    }
    return hash
}

/// Reading a stopped screen for whether the agent is *blocked on you* or merely
/// done. Both are your move, but only one is holding the agent up, and they
/// deserve different loudness — so this only has to be right often enough to be
/// worth the distinction. Guessing "blocked" wrongly costs a louder sound than
/// warranted; guessing "done" wrongly costs a quieter one. Neither loses the
/// notification, which is why the list stays short and generic instead of
/// growing a per-agent dialect that silently rots as agents restyle their UI.
enum AgentPrompt {
    /// Phrases that appear in the chrome of a prompt that is waiting for an
    /// answer — the affordance text, not the question, since the affordances
    /// are what the agents have in common.
    private static let blockedMarkers = [
        "y/n", "yes/no", "(y)es", "[y]es",
        "esc to cancel",
        "enter to select", "enter to confirm", "enter to continue", "press enter",
        "to navigate", "select an option", "choose an option",
        "do you want", "do you trust", "would you like",
        "waiting for your", "your response", "your approval",
        "permission", "approve", "authorize", "confirm",
    ]

    /// Phrases that mean the agent is *working* and you may interrupt it — the
    /// exact opposite of blocked, and easy to confuse with a prompt because both
    /// offer you Esc. Claude Code sits on "esc to interrupt" for the whole of a
    /// turn, which read as a permission prompt and made every false quiesce
    /// arrive at the loudest possible volume. Their presence vetoes the blocked
    /// reading outright.
    private static let workingMarkers = [
        "esc to interrupt", "esc to stop", "ctrl+c to stop", "ctrl-c to stop",
    ]

    /// True when the tail of a stopped screen reads as a prompt awaiting input.
    static func looksBlocked(_ screenTail: String) -> Bool {
        let text = screenTail.lowercased()
        guard !workingMarkers.contains(where: text.contains) else { return false }
        return blockedMarkers.contains { text.contains($0) }
    }
}
