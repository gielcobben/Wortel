import Foundation

/// What a program's report about itself comes to: a spinner, a dot, a banner,
/// or nothing.
///
/// A session whose program reports (`ProgramStatus`, OSC 7501) is taken at its
/// word, and this is the whole of how: one report in, what was last said, and
/// what follows. No title is read for it, no screen watched, no word in a
/// notification weighed. Those are for programs that say nothing.
///
/// Pure, so each rule is pinned by a test. A rule wrong one way is an agent
/// that finished and told nobody; wrong the other, a banner for nothing.
enum ReportedStatus {
    enum Effect: Equatable {
        /// It is working: the spinner. Whatever was about to be announced is
        /// off, because it carried on.
        case working
        /// It is not working, and that alone is no news.
        case resting
        /// It wants the user or has something for them. Raised once the state
        /// has stood for `settle`, with these words (nil: the agent's own
        /// last answer, read from its conversation, or the fixed words).
        case announce(AttentionKind, words: String?)
        /// The same, about something that happened while nobody was attached:
        /// the dot, with no banner and no sound for old news.
        case mark(AttentionKind, words: String?)
        /// It was blocked on the user and no longer is: what that raised has
        /// been answered, here or by the program giving up on it.
        case answered
        /// The program is gone, or handed the terminal to something else.
        /// Whoever runs there next has said nothing yet.
        case gone
    }

    /// How long `blocked`, `done` or `error` has to stand before it is
    /// announced. A program can change state as fast as it can write, and one
    /// that asks and is answered by a rule of its own, or finishes and starts
    /// the next queued message, passes through a state without ever having
    /// wanted anyone. Short, because past it every moment is a late banner.
    static let settle: TimeInterval = 0.4

    /// What follows from a program's records going from `before` to `after`
    /// (nil: it has said nothing, or has gone). `gone`: it cleared everything
    /// and left. `replayed`: read from what it wrote while nobody was
    /// attached, so it is what is true now and not an event.
    ///
    /// Two things are read, apart. The root record says whether the program
    /// is working or has finished. The block (`ProgramRecords.block`: the
    /// root, or a piece of its work) says whether it wants an answer. A block
    /// coming or going is never a turn starting or ending, so a question a
    /// background task asked, once answered, does not announce the finished
    /// turn behind it a second time.
    ///
    /// `idleEndsTurn`: this program has not shown that it tells a finished
    /// turn from a stopped one (it never says `done`), so going from `working`
    /// to `idle` is how its turns end. opencode reports only `working`,
    /// `blocked` and `idle`; taken literally, every turn it finished would
    /// end in silence.
    static func effects(from before: ProgramRecords?, to after: ProgramRecords?,
                        gone: Bool = false, replayed: Bool = false,
                        idleEndsTurn: Bool = false) -> [Effect] {
        let wasBlocked = before?.block != nil
        if gone { return (wasBlocked ? [.answered] : []) + [.gone] }
        var effects: [Effect] = wasBlocked && after?.block == nil ? [.answered] : []

        // The program itself. Said again, nothing changed: a program that
        // repeats itself per tool call must not be a banner per tool call.
        let was = before?.root, root = after?.root
        if let root, root != was {
            func tell(_ kind: AttentionKind, _ words: String?) -> Effect {
                replayed ? .mark(kind, words: words) : .announce(kind, words: words)
            }
            switch root.state {
            case .working:
                effects.append(.working)
            case .idle:
                // Also what an interrupted turn reports, and what `done`
                // becomes once the user has touched the program: no news,
                // unless going idle is the only way this program ends a turn.
                effects.append(.resting)
                if idleEndsTurn, was?.state == .working { effects.append(tell(.turnDone, nil)) }
            case .blocked:
                effects.append(.resting)
            case .done:
                // Its message is not quoted: where there is one it names the
                // session (Pi), which the banner's title already does.
                effects += [.resting, tell(.turnDone, nil)]
            case .error:
                effects += [.resting, tell(.failed, root.message.map(banner))]
            }
        }

        // What it is waiting on the user for: a new one, or other words.
        if let block = after?.block, block != before?.block {
            let words = block.message.map(banner) ?? blockedWords(block.kind)
            effects.append(replayed ? .mark(.needsInput, words: words) : .announce(.needsInput, words: words))
        }
        return effects
    }

    /// The longest a program's own line is shown at. It may send 2048 bytes;
    /// a banner holds a sentence.
    static let bannerLength = 180

    /// A program's line, cut to fit a banner: at a word, with an ellipsis.
    static func banner(_ words: String) -> String {
        guard words.count > bannerLength else { return words }
        let cut = words.prefix(bannerLength)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What a blocked program is waiting for, when it gave no words of its own.
    static func blockedWords(_ kind: ProgramStatus.Kind?) -> String {
        switch kind {
        case .permission: return "Waiting for your approval"
        case .question: return "Asking you a question"
        case .auth: return "Waiting for you to sign in"
        case nil: return "Waiting on you"
        }
    }

    /// An agent known to report its state, and what someone on an older
    /// version of it needs to be told.
    struct Reporter: Equatable {
        /// As a person writes it: "Codex".
        let name: String
        /// The first version that says everything Wortel listens for.
        let since: String
        /// Where its releases are described.
        let notes: URL
    }

    /// Agents known to report their state, by the name their marker carries.
    /// One of these running in silence is an old version of itself
    /// (`SessionManager.watchForSilence`). Not a list detection depends on:
    /// anything that reports is heard, named here or not.
    ///
    /// Each read in its own source on 2026-11-19. Codex reported from 0.163,
    /// and `done`, `error` and why it is blocked from 0.164. opencode is
    /// OpenCode V2 (`@opencode/cli`); the 1.x line (`opencode-ai`, 1.19.6
    /// that day) reports nothing, and is told to move to V2. Amp, Qwen Code
    /// and GitHub Copilot CLI report too and are left out: Amp's own code
    /// could not be read to say since when, and the other two have no marker.
    static let knownReporters: [String: Reporter] = [
        "codex": Reporter(name: "Codex", since: "0.164",
                          notes: URL(string: "https://github.com/openai/codex/releases")!),
        "claude": Reporter(name: "Claude Code", since: "2.1.295",
                           notes: URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!),
        "pi": Reporter(name: "Pi", since: "1.1.0",
                       notes: URL(string: "https://github.com/earendil-works/pi/releases")!),
        "opencode": Reporter(name: "opencode", since: "2.0.29",
                             notes: URL(string: "https://github.com/anomalyco/opencode/releases")!),
        "crush": Reporter(name: "Crush", since: "0.98.0",
                          notes: URL(string: "https://github.com/charmbracelet/crush/releases")!),
    ]

    /// Programs read to say `done` when a turn finishes, by the `app` they
    /// report. Their `idle` after `working` is a stop (an interrupt, a
    /// compaction, servers starting), never a finish. Any other program
    /// earns the same by saying `done` or `error` once
    /// (`SessionManager.saidDone`); until then its `idle` ends its turns
    /// (`effects`, `idleEndsTurn`).
    ///
    /// The list is what keeps Codex quiet while it starts its MCP servers,
    /// `working` then `idle`, before it has finished a first turn.
    static let saysDone: Set<String> = ["codex", "claude-code", "pi", "crush"]
}
