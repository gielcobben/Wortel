import Foundation


/// Why a background session is asking for the user's eyes. Ordered by urgency
/// (`priority`) so that when several signals could apply at once the most
/// important one wins the sidebar dot; each kind also decides whether its
/// native notification makes a sound. Colours are mapped in the UI layer so the
/// model stays AppKit-only.
enum AttentionKind {
    /// A program is *blocked on the user* — it made an explicit request: a
    /// permission / confirmation prompt, an "action required" title marker, a
    /// bell, or a program-authored desktop notification. Nothing proceeds until
    /// you answer, so this is the loudest state.
    case needsInput
    /// A command exited non-zero while the session was unselected.
    case failed
    /// An agent finished its turn and went quiet, with no explicit request —
    /// inferred from its own progress reporting stopping (which only long-lived
    /// programs emit; plain commands clear via a command-finished mark instead).
    /// It's your move, but nothing is blocked, so it arrives calmly and silent.
    case turnDone
    /// A plain long-running command finished cleanly while unselected. Purely
    /// informational.
    case finished

    /// Higher wins when two signals race (see `SessionManager.raiseAttention`),
    /// so an explicit request can never be masked by an inferred turn-end.
    var priority: Int {
        switch self {
        case .needsInput: return 4
        case .failed: return 3
        case .turnDone: return 2
        case .finished: return 1
        }
    }

    /// How loud this kind's native notification should be. Two audible tiers,
    /// deliberately tellable apart with the app in the background: a blocked
    /// prompt or a failure rings the standard alert, while an agent simply
    /// finishing its turn gets a quieter, shorter chime — you want to know it's
    /// your move without it sounding like something broke. A plain command
    /// finishing stays silent; that's what the sidebar dot is for.
    var chime: Chime {
        switch self {
        case .needsInput, .failed: return .alert
        case .turnDone: return .soft
        case .finished: return .none
        }
    }

    /// Sound tier for a kind's notification, mapped to a real sound in the app
    /// layer (the model stays free of UserNotifications).
    enum Chime {
        /// The system default notification sound.
        case alert
        /// A quiet, distinct chime for "your move, nothing is blocked".
        case soft
        /// Silent.
        case none
    }

    /// Whether the sidebar dot should breathe. Anything that wants your next
    /// action pulls the eye; a plain clean finish is calm and steady.
    var pulses: Bool {
        switch self {
        case .needsInput, .failed, .turnDone: return true
        case .finished: return false
        }
    }

    /// Sort a notification a program wrote itself (OSC 9 / 777 / 99), or a
    /// `wortel notify`: is it asking for something, or saying it is done?
    ///
    /// By how it opens, never by a word somewhere in it. Codex's turn-end
    /// notification is the start of its answer, with no fixed wording, and an
    /// answer says "review", "continue" and "confirm" all the time: sorted by
    /// keyword, with "needs input" as the fallback, four in five Codex turns
    /// arrived as the loudest kind (measured 2026-11-19). A request leads with
    /// its request ("Approval requested: …", "Waiting for Approval"), so only
    /// the title and the first words of the body are read, and anything that
    /// does not open as one is a turn that ended.
    ///
    /// Only for programs that do not report their own state: one that does
    /// (`ProgramStatus`) is never sorted by its words.
    static func classify(notificationTitle title: String, body: String) -> AttentionKind {
        if namesAFailure(title) { return .failed }
        let opening = title.lowercased() + " " + body.prefix(requestOpeningLength).lowercased()
        return requestOpenings.contains(where: opening.contains) ? .needsInput : .turnDone
    }

    /// Whether a title says something failed: "Tests failed", "Build error",
    /// "Failure: lint". A failure is only ever named in a title, which an
    /// agent's answer never is (`wortel notify "Tests failed"`). By whole
    /// word, and not one counted as none: "0 errors", "no failures" and
    /// "Tests: 0 failed" are a run that passed.
    static func namesAFailure(_ title: String) -> Bool {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (index, word) in words.enumerated() where failureWords.contains(word) {
            let before = index > 0 ? words[index - 1] : ""
            if !["0", "no", "zero", "without", "not"].contains(before) { return true }
        }
        return false
    }

    private static let failureWords: Set<String> = [
        "failed", "fails", "failure", "failures", "error", "errors", "errored", "crashed",
    ]

    /// How much of a notification's body can be its request. Codex's longest
    /// opening is "Approval requested: " (20); an answer's first sentence is
    /// past it before it gets to asking for anything.
    static let requestOpeningLength = 40

    /// How programs open a notification that asks for something. Codex before
    /// it reported its state ("Approval requested", "Codex wants to edit",
    /// "Plan mode prompt:", "Question:"), Amp ("Waiting for Approval"), Gemini
    /// ("Action Required"), Claude Code's own channel ("needs your permission",
    /// "waiting for your input").
    private static let requestOpenings = [
        "approval", "permission", "wants to edit", "action required",
        "plan mode prompt", "question:", "waiting for", "needs your",
    ]
}

extension AttentionKind {
    /// The loudest of several — what a collapsed folder shows on behalf of the
    /// sessions it's hiding.
    ///
    /// A rollup has to take the *maximum*, never the most recent: a folder
    /// holding one agent blocked on a permission prompt and three that merely
    /// finished must read as blocked. Taking the latest instead would let a
    /// tidy `finished` arriving a second later hide the thing you actually need
    /// to answer — which is the same rule `raiseAttention` applies to one
    /// session, applied to a group.
    static func loudest<S: Sequence>(of kinds: S) -> AttentionKind?
    where S.Element == AttentionKind? {
        kinds.compactMap { $0 }.max { $0.priority < $1.priority }
    }
}

/// What a signal from a session comes to, given what is already showing and
/// whether anyone is there.
///
/// Pure, because each way it is wrong is quiet: an agent that finished and
/// told nobody, or a sound per tool call.
enum AttentionRaise: Equatable {
    /// Nothing changes: someone is looking, something louder is showing, or
    /// exactly this is showing already.
    case ignore
    /// Show it. `alert`: make a sound (a fresh episode, or louder than what
    /// was showing). `startsEpisode`: nothing was showing, so "waiting since"
    /// starts now. `whileAway`: it is on screen and nobody is there, so being
    /// on screen later must not count as having seen it.
    case raise(alert: Bool, startsEpisode: Bool, whileAway: Bool)

    /// What is showing for the session now, as the banner has it.
    struct Standing: Equatable {
        var kind: AttentionKind
        var title: String
        var body: String
    }

    static func decide(
        kind: AttentionKind, title: String, body: String,
        current: AttentionKind?, standing: Standing?,
        activelyViewing: Bool, onScreen: Bool
    ) -> AttentionRaise {
        guard !activelyViewing else { return .ignore }
        if let current, current.priority > kind.priority { return .ignore }
        if let standing, standing.kind == kind, standing.title == title, standing.body == body {
            return .ignore
        }
        return .raise(alert: current.map { kind.priority > $0.priority } ?? true,
                      startsEpisode: current == nil,
                      whileAway: onScreen)
    }
}
