import Foundation

/// A session's worktree on its way: what was asked for, and how it's going.
/// Kept whole so a failure can be tried again exactly as it was asked.
struct WorktreePreparation: Equatable {
    /// The branch, as the sheet gave it.
    let branch: String
    /// The ref a new branch forks from; nil for the repository's default.
    let base: String?
    /// Where the repository was taken from: the session that was selected
    /// when Fork was pressed, not whichever is selected when git finishes.
    let from: String

    /// git's own words, once it has refused.
    var failure: String?
}
