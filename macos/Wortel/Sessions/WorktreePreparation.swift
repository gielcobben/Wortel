import Foundation

/// A session's worktree on its way: what was asked for, and how it's going.
/// Kept whole so a failure can be tried again exactly as it was asked.
struct WorktreePreparation: Equatable {
    /// What the worktree is for.
    enum Request: Equatable {
        /// A branch, as the sheet or `wortel new --branch` gave it; `base` is
        /// the ref a new one forks from, nil for the repository's default.
        case branch(String, base: String?)
        /// Fork Session: a new worktree at the source's commit, carrying its
        /// uncommitted work and forking its agent's conversation.
        case fork(ForkSource)
        /// A pull request, by number or URL, checked out from its remote.
        case pullRequest(PullRequestRef)
    }

    /// Where it has got to, for the page to say.
    enum Stage: Equatable {
        /// Waiting (briefly) for the fetch started beside the sheet.
        case fetching
        /// Reading the source's uncommitted changes, for a fork.
        case reading
        /// `git worktree add`.
        case checkingOut
        /// Putting a fork's changes into the new worktree.
        case applying
        /// Copying the ignored files `.worktreeinclude` names.
        case copying
    }

    let request: Request
    /// Where the repository was taken from: the session that was selected
    /// when Fork was pressed, not whichever is selected when git finishes.
    let from: String
    /// The branch, as shown on the page.
    var branch: String

    var stage: Stage = .checkingOut

    /// The worktree once git has made it, kept while the page waits on the
    /// person: to read the warnings, or to open it anyway after a step that
    /// came after `worktree add` failed.
    var resolved: ResolvedWorktree?

    /// Things worth knowing that didn't stop anything (a file not copied, a
    /// budget reached). With these the page waits for "Open Session" rather
    /// than replacing itself with a terminal that would hide them.
    var warnings: [String] = []

    /// git's own words, once it has refused.
    var failure: String?

    /// The worktree exists and the failure came after it: trying again would
    /// only find it there, so the page offers to open it instead.
    var worktreeExists: Bool { resolved != nil }

    init(request: Request, from: String, branch: String) {
        self.request = request
        self.from = from
        self.branch = branch
    }
}

/// What Fork Session was pressed on, captured at the press: the session can
/// move on (its agent writes, its shell `cd`s) while git works, and the fork
/// is of the moment it was asked for. A class, compared by identity, because
/// the snapshot it comes to hold is big and the request is copied around.
final class ForkSource: Equatable {
    /// The source session's name, for the page and the refusals.
    let name: String
    /// A branch name asked for (`wortel fork --branch`), else one is made.
    let branch: String?
    /// The agent running in the source, when it can fork its conversation
    /// (`AgentConversation.exact`), and how it was started.
    let agent: String?
    let argv: String?
    let model: String?
    /// The conversation it was in, when known. Without one the fork starts
    /// the agent fresh, with the same flags.
    let conversationID: String?
    /// Where the agent ran, which is where its transcript is filed.
    let agentCwd: String?

    /// The uncommitted work, once it has been read (the first stage). Kept
    /// so Try Again forks the same moment rather than a later one.
    var snapshot: WorktreeFork.Snapshot?

    init(name: String, branch: String?, agent: String?, argv: String?, model: String?,
         conversationID: String?, agentCwd: String?) {
        self.name = name
        self.branch = branch
        self.agent = agent
        self.argv = argv
        self.model = model
        self.conversationID = conversationID
        self.agentCwd = agentCwd
    }

    static func == (a: ForkSource, b: ForkSource) -> Bool { a === b }
}

/// A worktree git has made or found for a session.
struct ResolvedWorktree: Equatable {
    let path: String
    /// nil for a fork outside a repository, which opens in the same folder.
    let branch: String?
    /// The checkout the request came from, which is where ignored files are
    /// copied from.
    let sourceRoot: String
    /// Whether this request made it. A worktree that already existed is the
    /// branch's own and is opened as it is, never written into.
    let created: Bool
    /// Worth saying on the way (a pull request force-pushed since the copy
    /// here was taken).
    var notes: [String] = []
}
