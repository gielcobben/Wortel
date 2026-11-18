import Foundation
import os

/// What deep sleep did and why not.
///
///     log stream --level info --predicate 'subsystem == "com.gielcobben.Wortel" && category == "sleep"'
enum AgentSleepLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "sleep")
}

/// An agent Wortel ended to give its memory back, and what brings it back.
///
/// Captured **before** the agent is ended, from the agent itself, so the
/// resume is to the conversation it said it was in and not to a guess made
/// afterwards.
struct SleepingAgent: Equatable {
    /// The run that was ended, as its marker described it.
    let marker: AgentMarker
    let conversationID: String
    /// The line that resumes it, as `AgentResumeStore.resumeInput` built it.
    let input: String
    /// It was waiting on the person, or had something running, when it went:
    /// the long clock. Kept so a relaunch says the same.
    let waiting: Bool
    let since: Date
    /// When the resume was last typed, while waiting to see the agent start.
    var typedAt: Date?
    /// How many times the resume has been typed without the agent starting.
    var attempts = 0
}

/// Where a session's agent is, as far as sleep goes.
enum AgentSleepState: Equatable {
    case awake
    /// The signal is sent and the agent has not been seen to go yet.
    case ending(SleepingAgent, signalledAt: Date, group: pid_t)
    case asleep(SleepingAgent)

    var sleeper: SleepingAgent? {
        if case .asleep(let agent) = self { return agent }
        return nil
    }

    var isEnding: Bool {
        if case .ending = self { return true }
        return false
    }

    /// The agent that is asleep or on its way there: what a save records, so
    /// a crash between the signal and the agent going still knows of it.
    var agent: SleepingAgent? {
        switch self {
        case .awake: return nil
        case .ending(let agent, _, _), .asleep(let agent): return agent
        }
    }
}

/// What the agent's own record says it is doing, when it is not working.
enum AgentRest: Equatable {
    /// Its turn is done and it is at its prompt.
    case finished(since: Date)
    /// It is waiting on the person (a question, a plan, a permission
    /// prompt), or at its prompt with a shell of its own still running: the
    /// long clock either way.
    case waiting(since: Date)
    /// Working, or nothing Wortel can read. Never slept on.
    case unknown

    /// From Claude Code's own word for it (`~/.claude/sessions/<pid>.json`,
    /// `status`). Seen on 2.1.327, 2026-11-18: `idle` at its prompt, `busy`
    /// in a turn, `waiting` at an AskUserQuestion and at a permission prompt
    /// (`waitingFor` says which), and `shell` at its prompt after a turn
    /// that left a background command running (`python3 -m http.server`).
    /// Anything else, `busy` included, is unknown.
    init(claudeStatus status: String?, since: Date?) {
        guard let since else { self = .unknown; return }
        switch status {
        case "idle": self = .finished(since: since)
        case "waiting", "shell": self = .waiting(since: since)
        default: self = .unknown
        }
    }
}

/// Deep sleep: when an idle agent is ended, and what makes it wait.
///
/// An idle Claude Code holds 130 to 400 MB (measured 2026-11-18: fourteen of
/// them, 3.1 GB), and hibernation only frees the terminal. So an agent that
/// has finished its turn, in a session nobody is looking at, is ended after
/// an hour, and the exact conversation is resumed when the session is
/// selected again. The shell stays. Chosen knowingly as the exception to
/// "the agent is never killable" (`docs/decisions.md`, 2026-11-18).
///
/// This type is only the decision, as values, so every rule can be read and
/// tested. The signal and the typing are `SessionManager`'s.
///
/// **Every doubt is a reason to stay awake.** An agent that sleeps when it
/// should not has lost something; one that stays awake has cost some memory.
enum AgentSleep {
    /// Agents that may sleep: resumable by exact conversation, and each one
    /// checked with the real agent (that it says when it is idle, ends
    /// cleanly on SIGTERM, leaves the terminal as a shell's, and resumes in
    /// place). A constant, like `HibernationPolicy.watchableAgents`.
    static let enabledAgents: Set<String> = ["claude"]

    /// A finished agent, out of sight this long, sleeps.
    static let finishedAfter = seconds("WORTEL_SLEEP_AFTER", 60 * 60)
    /// One waiting on the person, or with something still running under it,
    /// gets this long: a question left overnight, not one left over lunch.
    static let waitingAfter = seconds("WORTEL_SLEEP_WAITING_AFTER", 8 * 60 * 60)
    /// Under memory pressure a finished agent needs only this much rest.
    static let pressureFloor: TimeInterval = min(finishedAfter, 10 * 60)
    /// How long an agent has to go after the signal before the session is
    /// simply counted as awake again.
    static let exitGrace: TimeInterval = 10
    /// How long a session has to stay selected before its agent is resumed,
    /// so stepping through rows does not start each one.
    static let wakeDwell: TimeInterval = 0.3
    /// A resume is typed at most this many times without the agent starting.
    static let maxWakeAttempts = 3

    private static func seconds(_ name: String, _ fallback: TimeInterval) -> TimeInterval {
        if let value = ProcessInfo.processInfo.environment[name],
           let seconds = TimeInterval(value), seconds > 0 { return seconds }
        return fallback
    }

    struct Inputs: Equatable {
        /// The agent running in the session, nil for a plain shell.
        var agent: String?
        /// It was started by one plain command: after `claude; make`, ending
        /// the agent would let the shell go on to run `make`.
        var launchIsSimple = true
        /// An exact conversation is known, is on disk, and has a resume line.
        var resumable = false
        /// The app holds the session's pty (a keeper session).
        var hasTerminal = true
        var selected = false
        /// Working, by any of Wortel's own signals.
        var busy = false
        /// What the agent's own record says.
        var rest: AgentRest = .unknown
        /// When Wortel last saw it stop working, if it has.
        var quietSince: Date?
        /// When the session was last on screen, or the launch.
        var hiddenSince: Date
        /// Something the agent started is still running.
        var hasWorkUnder = false
        /// Keys went into the session since the agent came to rest: maybe a
        /// prompt half written.
        var typedSinceRest = false
        var now: Date
    }

    enum Reason: Equatable {
        case notAnAgent, notEnabled, launchNotSimple, notResumable, noTerminal, selected, busy, restUnknown
    }

    enum Verdict: Equatable {
        case never(Reason)
        /// Not yet: ask again then.
        case notBefore(Date)
        /// Now. `waiting` says which clock it was on.
        case sleep(waiting: Bool)
    }

    /// Whether the agent in a session may be ended now. `pressure` is a
    /// memory warning from macOS, which shortens only the finished clock.
    static func decide(_ inputs: Inputs, pressure: Bool = false) -> Verdict {
        guard let agent = inputs.agent else { return .never(.notAnAgent) }
        guard enabledAgents.contains(agent) else { return .never(.notEnabled) }
        guard inputs.launchIsSimple else { return .never(.launchNotSimple) }
        guard inputs.resumable else { return .never(.notResumable) }
        guard inputs.hasTerminal else { return .never(.noTerminal) }
        guard !inputs.selected else { return .never(.selected) }
        guard !inputs.busy else { return .never(.busy) }

        let restSince: Date
        var waiting = inputs.hasWorkUnder || inputs.typedSinceRest
        switch inputs.rest {
        case .unknown: return .never(.restUnknown)
        case .finished(let since): restSince = since
        case .waiting(let since): restSince = since; waiting = true
        }
        let interval = waiting ? waitingAfter : (pressure ? pressureFloor : finishedAfter)
        // Every way the clock restarts is one of these being later.
        let from = max(restSince, inputs.hiddenSince, inputs.quietSince ?? .distantPast)
        let deadline = from.addingTimeInterval(interval)
        return inputs.now >= deadline ? .sleep(waiting: waiting) : .notBefore(deadline)
    }
}
