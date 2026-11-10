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

    /// Classify a program-authored desktop notification (OSC 9 / 777 / 99). An
    /// explicit notification usually means the program wants you *now*, so the
    /// default is the blocking `.needsInput`; it's only softened to `.turnDone`
    /// when the text clearly reads as a completion with nothing left to approve.
    /// Keyword matching only has to break the tie for this one ambiguous source —
    /// every other signal is classified by where it comes from.
    static func classify(notificationTitle title: String, body: String) -> AttentionKind {
        let text = (title + " " + body).lowercased()
        let blocking = ["permission", "approve", "allow", "confirm", "authoriz",
                        "waiting", "input", "action required", "review",
                        "continue", "proceed", "respond", "y/n", "question"]
        if blocking.contains(where: text.contains) { return .needsInput }
        let completion = ["completed", "complete", "finished", "done", "success"]
        if completion.contains(where: text.contains) { return .turnDone }
        return .needsInput
    }
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

/// What each session has had in front of someone, and for how long: whether a
/// turn's end was already read before anything announced it.
///
/// It is not the same question as `AttentionRaise`'s "is anyone looking right
/// now". The screen tier decides a turn is over once the screen has held
/// still for a few seconds, and your own scrolling restarts that wait (so it
/// never reads as the agent working). Reading a long answer to its end and
/// ⌘-tabbing away therefore ended the turn, as far as Wortel knew, a few
/// seconds *after* you left, and you got a banner quoting the answer you had
/// just read. What settles it is when the conversation was last written: if
/// that was on screen, with you there, for `dwell` before you left, you saw
/// how the turn ended.
///
/// Pure, so its arithmetic is pinned by tests: off one way it hides a turn
/// that finished behind your back, off the other it is the banner it exists
/// to stop.
struct SeenLedger: Equatable {
    /// How long something has to be in front of you to count as read: the
    /// same second the quieter unread ring takes to clear.
    static let dwell: TimeInterval = 1

    /// The session on screen now, with someone there, and since when.
    private(set) var showing: UUID?
    private var showingSince: Date?
    /// Per session: everything written at or before this was on screen for
    /// `dwell` while someone was there.
    private var seenThrough: [UUID: Date] = [:]

    /// What is on screen changed: `id`, or nothing (Wortel in the background,
    /// the window covered). `present` says whether anyone was at the Mac as
    /// the last stretch ended; a window left on screen for an empty room
    /// showed nobody anything.
    mutating func show(_ id: UUID?, at now: Date, present: Bool) {
        guard id != showing else { return }
        if let old = showing, let since = showingSince, present,
           now.timeIntervalSince(since) >= Self.dwell {
            let through = now.addingTimeInterval(-Self.dwell)
            seenThrough[old] = max(seenThrough[old] ?? through, through)
        }
        showing = id
        showingSince = id == nil ? nil : now
    }

    /// Whether what `id`'s conversation looked like once it was written at
    /// `written` has been in front of someone for `dwell`, now or before.
    /// `present`: whether anyone is at the Mac now, which the stretch still
    /// on screen needs to count: a window in front of an empty room is the
    /// turn that finished while you were getting coffee, and that one is news.
    func saw(_ id: UUID, writtenAt written: Date, now: Date, present: Bool) -> Bool {
        if id == showing, present, let since = showingSince,
           now.timeIntervalSince(max(since, written)) >= Self.dwell {
            return true
        }
        return seenThrough[id].map { written <= $0 } ?? false
    }

    /// A closed session's history goes with it.
    mutating func forget(_ id: UUID) {
        seenThrough[id] = nil
        if showing == id { showing = nil; showingSince = nil }
    }
}
