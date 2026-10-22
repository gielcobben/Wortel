import Foundation

/// Moving a session to another directory (`wortel cd`, Change Directory):
/// what decides whether and when it can happen, what gets typed, and what the
/// caller is told. Pure, so `SessionMoveTests` can pin it; `SessionManager`
/// gathers the facts and does the moving.
///
/// A move never restarts the shell (that would lose its scrollback, history
/// and jobs). It types into it: `cd <dir>`, then, if an agent was running,
/// that agent's resume. An agent holds the terminal, so it is quit first, and
/// only once its turn has really ended: quit mid tool call and the
/// conversation it resumes ends in a question nobody answered.
enum SessionMove {
    /// What the session looks like at the moment of asking.
    struct Situation: Equatable {
        var directoryExists = true
        var sameDirectory = false
        /// Still waiting for its worktree.
        var preparing = false
        /// There's a pty to type into (not the exec backend).
        var hasPty = true
        /// The agent the session's shell is running (its marker), nil for a
        /// plain shell.
        var agent: String?
        var conversationID: String?
        /// Its process was found under the shell.
        var agentFound = true
        /// Suspended with ^Z.
        var agentStopped = false
        /// The agent replaced its shell (`exec claude`): quit, it takes the
        /// session's shell with it, and there's nothing left to type into.
        var agentIsShell = false
        /// Nothing but the shell has the terminal: it's at its prompt.
        var shellInForeground = true
        /// The agent is what has the terminal.
        var agentInForeground = false
        /// The command came from what has the terminal: `wortel cd` typed at
        /// the prompt, or run by a script started there.
        var callerInForeground = false
        /// The command came from the agent itself (its shell tool), however
        /// deep.
        var callerIsAgent = false
        /// What has the terminal when it's neither the shell nor the agent.
        var foregroundName: String?
    }

    enum Decision: Equatable {
        /// Type the `cd` now: a plain shell at its prompt.
        case now
        /// Type it at the next prompt: the `wortel` that asked is still
        /// running there.
        case atPrompt
        /// Quit the agent once it's idle, then type. `needsTurnEnd` when the
        /// agent asked: it is mid-turn by definition, and idle means a turn
        /// that ended *after* it asked, however quiet it looks now.
        case whenIdle(needsTurnEnd: Bool)
        case refuse(String)
    }

    /// Whether, and when, the session can move to `path`.
    static func decide(_ s: Situation, to path: String) -> Decision {
        let shown = display(path)
        guard s.directoryExists else { return .refuse("No such directory: \(shown)") }
        guard !s.preparing else { return .refuse("This session is still being set up.") }
        guard !s.sameDirectory else { return .refuse("Already in \(shown).") }
        guard s.hasPty else { return .refuse("Wortel can't type into this session's shell.") }
        guard let agent = s.agent else {
            if s.shellInForeground { return .now }
            if s.callerInForeground { return .atPrompt }
            return .refuse(busy(s.foregroundName))
        }
        guard AgentConversation.movable.contains(agent) else {
            return .refuse("Wortel can't carry \(agent)'s conversation to another directory. "
                + "Quit \(agent) first, then run wortel cd again.")
        }
        guard !s.agentStopped else {
            return .refuse("\(agent) is suspended. Bring it back with fg, or quit it, then move.")
        }
        guard s.agentFound else { return .refuse("Wortel can't find \(agent)'s process in this session.") }
        guard !s.agentIsShell else {
            return .refuse("\(agent) replaced this session's shell (exec), so quitting it would end the session. "
                + "Start \(agent) without exec to be able to move it.")
        }
        guard s.conversationID != nil else {
            return .refuse("Wortel can't tell which \(agent) conversation this is.")
        }
        guard s.agentInForeground else {
            if s.shellInForeground {
                return .refuse("\(agent) is running in the background here. Bring it back with fg, or quit it, then move.")
            }
            return .refuse(busy(s.foregroundName))
        }
        return .whenIdle(needsTurnEnd: s.callerIsAgent)
    }

    private static func busy(_ name: String?) -> String {
        name.map { "Something is running in this session (\($0)). Stop it first, then move." }
            ?? "Something is running in this session. Stop it first, then move."
    }

    /// The lines to type, in order: the `cd`, then the resume if there is one.
    /// Two lines, never `cd x && claude …`: the shell integration reads the
    /// agent's directory from `$PWD` when the agent starts, and only zsh's
    /// reader follows a `cd` on the same line through a quoted path, so in
    /// bash or fish the resumed agent would go untracked (no marker: no busy
    /// dot, no resume after a relaunch). nil when the path can't be typed
    /// safely in every shell: a control character, or a backslash, which
    /// fish reads as an escape even inside single quotes.
    static func lines(path: String, resume: String?) -> [String]? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" })
        else { return nil }
        let quoted = AgentCommandLine.isPlain(path)
            ? path
            : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["cd \(quoted)"] + (resume.map { [$0] } ?? [])
    }

    /// What the caller is told when the move is accepted.
    ///
    /// Written for an agent to read and pass on: it says what will happen,
    /// and that nothing has happened yet, because a command called `cd` reads
    /// as if it took effect at once.
    static func acceptedMessage(_ decision: Decision, agent: String?, path: String,
                                instead previous: String? = nil, fromSideTerminal: Bool = false,
                                stopping backgroundJobs: [String] = [], terminalStaysIn: String? = nil) -> String {
        let shown = display(path)
        var parts: [String] = []
        if let previous { parts.append("Moving to \(shown) instead of \(display(previous)).") }
        switch decision {
        case .now, .atPrompt:
            if previous == nil { parts.append("Moving this session to \(shown).") }
        case .whenIdle(let needsTurnEnd):
            let agent = agent ?? "The agent"
            let when = needsTurnEnd ? "When this turn ends" : "As soon as \(agent) is idle"
            parts.append("Not moved yet. \(when), \(agent) quits, and continues this conversation in \(shown), then waits for you.")
            if !backgroundJobs.isEmpty {
                let jobs = backgroundJobs.joined(separator: ", ")
                parts.append("\(jobs) (started by \(agent)) stops when it quits.")
            }
        case .refuse(let message):
            return message
        }
        if fromSideTerminal, let stays = terminalStaysIn {
            parts.append("This terminal stays in \(display(stays)).")
        }
        return parts.joined(separator: " ")
    }

    /// A path as a person reads it: under home, with `~`.
    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The row's second line while a move waits, and the menu's Cancel.
    static func pendingLine(to path: String) -> String {
        "Moving to \((path as NSString).lastPathComponent) after this turn"
    }
}

/// A move that has been accepted and hasn't finished. Lives on the session
/// in memory only: a quit drops it (a relaunch has no turn to wait for).
struct PendingMove {
    enum Stage: Equatable {
        /// Waiting for the agent to be idle.
        case waiting
        /// The agent was told to quit; waiting for the shell's prompt.
        case stopping(since: Date)
        /// Waiting for the prompt the `wortel` that asked returns to.
        case atPrompt
        /// Typed; waiting for the shell to report the new directory.
        case typed(at: Date)
    }

    let path: String
    let requestedAt: Date
    /// The agent asked, so only a turn ending after `requestedAt` counts.
    let needsTurnEnd: Bool
    /// The agent being carried, as it was running: what its resume is built
    /// from. nil for a plain shell.
    let agent: AgentMarker?
    /// The agent's process group when the move was asked for: the only group
    /// it may signal.
    let agentGroup: pid_t?
    let conversationID: String?
    let via: MoveOrigin
    var stage: Stage
    /// A busy-to-idle edge was seen after `requestedAt`.
    var sawTurnEnd = false
    /// Consecutive samples the agent looked idle; two are needed.
    var idleSamples = 0
}
