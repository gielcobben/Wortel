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
    /// It was waiting on the person, had something running, or could be
    /// reached by Remote Control, when it went: the long clock. Only what a
    /// save says of it (`agentAsleep`), and the log.
    let waiting: Bool
    /// When the resume was last typed, while waiting to see the agent start.
    var typedAt: Date?
    /// How many times the resume has been typed without the agent starting.
    var attempts = 0
}

/// Where a session's agent is, as far as sleep goes.
enum AgentSleepState: Equatable {
    case awake
    /// The signal is sent and the agent has not been seen to go yet.
    case ending(SleepingAgent, group: pid_t)
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
        case .ending(let agent, _), .asleep(let agent): return agent
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

    /// From what a program says of itself (`ProgramRecords`, OSC 7501), for
    /// an agent with no record of its own to read: Codex. `since` is when it
    /// stopped saying `working`.
    ///
    /// `idle` and `done` are at rest. A block, its own or a piece of its
    /// work's, is waiting on the person, and so is a piece of work still
    /// going while the root says it is done. `error` is left unknown: a turn
    /// that failed is something to look at, not to restart over.
    init(reported records: ProgramRecords?, since: Date?) {
        guard let records, let root = records.root, let since else { self = .unknown; return }
        if records.block != nil { self = .waiting(since: since); return }
        switch root.state {
        case .idle, .done:
            let stillGoing = records.childrenInOrder.contains { $0.state == .working }
            self = stillGoing ? .waiting(since: since) : .finished(since: since)
        case .working, .blocked, .error:
            self = .unknown
        }
    }
}

/// What asking for a sleeping agent back came to (`SessionManager.wake`).
enum AgentWake: Equatable {
    /// There is nothing asleep here.
    case notAsleep
    /// The resume has been typed, now or a moment ago, or the agent is still
    /// on its way out and will be brought straight back.
    case starting
    /// The shell is not at a prompt: still starting, or busy with something
    /// else. Nothing was typed.
    case shellBusy
    /// The resume was typed as often as it will be and never started. The
    /// session is a plain shell from here on.
    case gaveUp
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

    /// Agents that are ended to be repainted when light and dark change
    /// (`docs/appearance.md`): the same checks, and that it says itself when
    /// it is idle. Claude Code by its own record, Codex by its status
    /// reports (0.164 and later; an older one says nothing and is left).
    /// Pi follows a change by itself and no Pi that reports was at hand to
    /// check, so it is not here.
    static let repaintAgents: Set<String> = ["claude", "codex"]

    /// An agent painted for the other appearance, at rest and out of sight
    /// this long, is ended. Short, because it is unreadable now; not nothing,
    /// so stepping away from a session for a moment does not end its agent.
    static let repaintAfter = seconds("WORTEL_REPAINT_AFTER", 20)
    /// The one in front when the appearance changed is restarted where it
    /// stands once it has been at rest this long: a turn that ended a second
    /// ago is still being read.
    static let repaintInPlaceAfter: TimeInterval = min(repaintAfter, 5)

    /// A finished agent, out of sight this long, sleeps.
    static let finishedAfter = seconds("WORTEL_SLEEP_AFTER", 60 * 60)
    /// One waiting on the person, with something still running under it, or
    /// with Remote Control on, gets this long: a question left overnight, not
    /// one left over lunch, and a session you may pick up from your phone
    /// during the day. Nothing on the phone can wake one that is asleep.
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
        /// Remote Control is on, so it may be used from somewhere other than
        /// this Mac. Not never: someone with Remote Control on for every
        /// session would never get deep sleep at all.
        var remoteControl = false
        /// It drew itself for light and the Mac is now dark, or the other
        /// way round (`SessionManager.isPaintedForTheOtherAppearance`).
        var repaint = false
        /// Keys, a paste or a script's text went in since it last started
        /// working: maybe a prompt half written, or a `/new` that moved it to
        /// another conversation. Not a click or a scroll, which
        /// `typedSinceRest` also counts: reading an answer is not typing one.
        var keysSinceWork = false
        /// It was in front when the appearance changed, and is still: it may
        /// be restarted where it stands.
        var inPlace = false
        var now: Date
    }

    enum Reason: Equatable {
        case notAnAgent, notEnabled, launchNotSimple, notResumable, selected, busy, restUnknown
        /// Painted for the other appearance, and not ended for it: text was
        /// typed, something runs under it, it waits on an answer, or Remote
        /// Control is on. For an agent with no clock of its own.
        case held
    }

    enum Verdict: Equatable {
        case never(Reason)
        /// Not yet: ask again then.
        case notBefore(Date)
        /// Now. `waiting` says which clock it was on.
        case sleep(waiting: Bool)
        /// Now, so that it comes back painted for the appearance of the day.
        case repaint
    }

    /// Whether the agent in a session may be ended now. `pressure` is a
    /// memory warning from macOS, which shortens only the finished clock.
    static func decide(_ inputs: Inputs, pressure: Bool = false) -> Verdict {
        guard let agent = inputs.agent else { return .never(.notAnAgent) }
        let repaints = inputs.repaint && repaintAgents.contains(agent)
        guard enabledAgents.contains(agent) || repaints else { return .never(.notEnabled) }
        guard inputs.launchIsSimple else { return .never(.launchNotSimple) }
        guard inputs.resumable else { return .never(.notResumable) }
        // In front it is only ever restarted where it stands, and only the
        // one that was in front at the change itself.
        let inPlace = repaints && inputs.selected && inputs.inPlace
        guard !inputs.selected || inPlace else { return .never(.selected) }
        guard !inputs.busy else { return .never(.busy) }

        let restSince: Date
        var waiting = inputs.hasWorkUnder || inputs.typedSinceRest || inputs.remoteControl
        // What keeps a repaint off is narrower in one way (a click or a
        // scroll is not a prompt) and wider in none.
        var held = inputs.hasWorkUnder || inputs.keysSinceWork || inputs.remoteControl
        switch inputs.rest {
        case .unknown: return .never(.restUnknown)
        case .finished(let since): restSince = since
        case .waiting(let since): restSince = since; waiting = true; held = true
        }
        if repaints, !held {
            let quiet = max(restSince, inputs.quietSince ?? .distantPast)
            let deadline = inPlace ? quiet.addingTimeInterval(repaintInPlaceAfter)
                                   : max(quiet, inputs.hiddenSince).addingTimeInterval(repaintAfter)
            return inputs.now >= deadline ? .repaint : .notBefore(deadline)
        }
        // Held, or not painted wrong: the ordinary clocks, for the agents
        // that have them. In front, nothing.
        guard enabledAgents.contains(agent) else { return .never(.held) }
        guard !inputs.selected else { return .never(.selected) }
        let interval = waiting ? waitingAfter : (pressure ? pressureFloor : finishedAfter)
        // Every way the clock restarts is one of these being later.
        let from = max(restSince, inputs.hiddenSince, inputs.quietSince ?? .distantPast)
        let deadline = from.addingTimeInterval(interval)
        return inputs.now >= deadline ? .sleep(waiting: waiting) : .notBefore(deadline)
    }
}
