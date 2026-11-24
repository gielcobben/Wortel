import Foundation

/// A `wortel close` that has been accepted and hasn't happened yet. In memory
/// only: a quit drops it, and the session stays.
///
/// It waits for two things: the agent's turn to end, so its reply isn't cut
/// off, and the person's answer about any uncommitted files in the worktree
/// (`SessionManager.closeFromCommand`).
struct PendingClose {
    let requestedAt: Date
    /// The agent was working when asked: the close waits for that turn to end.
    let busyWhenAsked: Bool
    /// The turn has ended since.
    var turnEnded = false
    /// The worktree is being looked at for uncommitted files.
    var inspecting = false
    /// The person is being asked whether those files may go to the Trash.
    var asking = false
    /// The files they said may go, as `WorktreeReport.changedFiles` lists them.
    var accepted: Set<String> = []
    /// They said to keep the worktree.
    var kept = false

    /// A close still waiting this long is given up, and the person told.
    static let patience: TimeInterval = 60 * 60

    /// The reply the agent reads. `worktreeIsWortels` is nil for a session
    /// that isn't in a worktree, and false for one in a worktree another tool
    /// made, which Wortel never removes.
    static func acceptedMessage(waitsForTurn: Bool, worktreeIsWortels: Bool?) -> String {
        var parts = [waitsForTurn
            ? "This session closes when your turn ends. Finish your reply and start nothing else; "
                + "anything still running then stops."
            : "Closing this session."]
        switch worktreeIsWortels {
        case true?:
            parts.append("Wortel moves its worktree to the Trash, with the branch if nothing on it is "
                + "unique, and asks the person first if there are uncommitted files. "
                + "Don't remove the worktree or the branch yourself.")
        case false?:
            parts.append("Wortel didn't make its worktree, so the worktree stays; the session is "
                + "archived, and \u{2318}P brings it back.")
        case nil:
            break
        }
        return parts.joined(separator: " ")
    }
}

/// The question put to the person before uncommitted files go to the Trash.
enum TrashChangesQuestion {
    static let trash = "Move to Trash"
    static let keep = "Keep Worktree"

    static func title(session: String) -> String {
        "Move the worktree of \u{201c}\(session)\u{201d} to the Trash?"
    }

    /// The files by name, the first few, as `git status` gives them.
    static func detail(changes: [String]) -> String {
        let count = changes.count
        let named = changes.prefix(3).joined(separator: ", ")
        let more = count > 3 ? " and \(count - 3) more" : ""
        let noun = count == 1 ? "file that isn\u{2019}t" : "files that aren\u{2019}t"
        return "The agent closed this session, and its worktree has \(count) \(noun) committed: "
            + "\(named)\(more). They go to the Trash with it, so you can still get them back from there.\n\n"
            + "\(keep) archives the session as it is, and \u{2318}P brings it back."
    }
}

/// How a `wortel close` was answered, for the archive that follows it.
struct AskedClose: Equatable {
    /// The uncommitted files the person said may go to the Trash.
    var accepted: Set<String>
    /// They said to keep the worktree: it is archived as a click archives it.
    var kept: Bool
}
