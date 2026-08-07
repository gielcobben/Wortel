import Foundation

/// The gate in front of auto-naming: decides whether a session has changed
/// enough, recently enough, to be worth summarising again.
///
/// Pure and separate from `SessionManager` because every one of its failure
/// modes is timing-shaped and invisible: too eager and the sidebar relabels
/// itself while you read it, too shy and a session keeps a name that stopped
/// being true an hour ago. A fake clock is the only way to pin that.
///
/// The shape is cmux's (`manaflow-ai/cmux`, `AutoNamingConfig`), which gets two
/// things right that a plain timer doesn't:
///
/// - **Growth, not change.** "Has the screen changed?" is answered yes by a
///   spinner. The question worth asking is how much is *new* — a turn that
///   added six lines has something to say about itself; one that redrew a
///   progress bar does not.
/// - **Cooldown from the last attempt, not the last success.** Anchor it on
///   success and a summariser that keeps failing retries at full speed forever,
///   because nothing ever records that it ran.
///
/// What differs is the input. cmux reads each agent's transcript file, so its
/// growth is literally appended lines; ours is a screen scrape, which is a
/// viewport — text leaves it as well as arrives. So growth here is "lines not
/// present last time", which behaves the same for a scrolling session and
/// degrades sensibly for one that redraws in place.
struct AutoNameThrottle {
    struct Config {
        /// Minimum seconds between attempts for one session. Lower than cmux's
        /// 180 because the model is on-device and free — what this is really
        /// protecting is the reader, not a budget.
        var minInterval: TimeInterval = 45
        /// Below this there is too little on screen to name anything from.
        var minCharacters = 80
        var minLines = 10
        /// Lines that must be *new* since the last naming before spending
        /// another call. The first naming of a session is exempt.
        var minGrowth = 6
        /// How long an in-flight pass may be outstanding before another may
        /// start. A pass that never returns — a cancelled task, a hung model —
        /// must not wedge a session's naming permanently.
        var inFlightExpiry: TimeInterval = 90
    }

    /// One session's throttle state. `lastAttemptAt` records attempts, not
    /// successes: see the note above.
    struct State: Equatable {
        var lastAttemptAt: Date?
        var lastLines: Set<Int>?
        var inFlightSince: Date?

        init(lastAttemptAt: Date? = nil, lastLines: Set<Int>? = nil, inFlightSince: Date? = nil) {
            self.lastAttemptAt = lastAttemptAt
            self.lastLines = lastLines
            self.inFlightSince = inFlightSince
        }
    }

    enum Decision: Equatable {
        /// Summarise, and remember these lines as the new baseline.
        case proceed(lines: Set<Int>)
        case inFlight
        case tooSoon
        /// Not enough on screen — a fresh shell, a cleared terminal, a session
        /// showing nothing but a prompt.
        case tooLittleOnScreen
        /// The screen has moved, but not by enough to have a new topic.
        case insufficientGrowth
    }

    var config = Config()

    /// `screen` is the distilled scrape — chrome already stripped.
    func decide(screen: String, state: State, now: Date) -> Decision {
        if let since = state.inFlightSince,
           now.timeIntervalSince(since) < config.inFlightExpiry {
            return .inFlight
        }
        if let last = state.lastAttemptAt,
           now.timeIntervalSince(last) < config.minInterval {
            return .tooSoon
        }
        guard screen.count >= config.minCharacters else { return .tooLittleOnScreen }

        let lines = Self.fingerprint(screen)
        guard lines.count >= config.minLines else { return .tooLittleOnScreen }
        guard let seen = state.lastLines else { return .proceed(lines: lines) }
        guard lines.subtracting(seen).count >= config.minGrowth else {
            return .insufficientGrowth
        }
        return .proceed(lines: lines)
    }

    /// A screen as a set of line hashes. Hashes rather than the text because
    /// this is kept per session for the lifetime of the app and only ever
    /// compared — and a set rather than a count because a viewport's lines
    /// move: what matters is which lines are new, not how many there are.
    static func fingerprint(_ screen: String) -> Set<Int> {
        Set(screen.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hashValue })
    }
}
