import Foundation

/// A session's worktree on its way: what was asked for, and how it's going.
/// Kept whole so a failure can be tried again exactly as it was asked.
struct WorktreePreparation: Equatable {
    /// What the worktree is for.
    enum Request: Equatable {
        /// A branch, as the sheet or `wortel new --branch` gave it; `base` is
        /// the ref a new one forks from, nil for the repository's default.
        case branch(String, base: String?)
        /// A pull request, by number or URL, checked out from its remote.
        case pullRequest(PullRequestRef)
    }

    /// Where it has got to, for the page to say.
    enum Stage: Equatable {
        /// Waiting (briefly) for the fetch started beside the sheet.
        case fetching
        /// `git worktree add`.
        case checkingOut
        /// Copying the ignored files `.worktreeinclude` names.
        case copying
    }

    let request: Request
    /// Where the repository was taken from: the session that was selected
    /// when it was asked for, not whichever is selected when git finishes.
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

/// A worktree git has made or found for a session.
struct ResolvedWorktree: Equatable {
    let path: String
    /// The branch checked out there; nil for a detached one.
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
