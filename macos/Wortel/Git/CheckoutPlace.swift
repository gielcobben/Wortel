import Foundation

/// What the git panel calls a checkout of the repository: the worktree chip,
/// the worktree list, "In other folders" in the branch list, the clean pane's
/// "N changes in …", and what Bring Here says.
///
/// **By the session, not the folder.** The session is the unit
/// (`docs/worktrees.md`); a worktree is where one lives. A worktree's folder
/// is named once, when it's made, and never moves (agents key history by
/// directory), so after a placeholder branch is renamed for the work the
/// folder still reads `worktree-brave-river-1a2f`, which names nothing anyone
/// remembers. The session in it has the name you know it by; without one, the
/// branch is the next best (it's renamed for the work too); the folder is
/// last. The repository's own folder is the exception: its name is the
/// repository's, and its branch is already on the chip beside it.
enum CheckoutPlace {
    /// A live session and the checkouts it's in: the one it lives in (opened
    /// in, archived with), and the one its shell has `cd`'d into.
    struct Live: Equatable {
        var home: String?
        var visiting: String?
        let name: String
    }

    /// An archived session and the worktree it waits in.
    struct Archived: Equatable {
        let checkout: String
        let name: String
    }

    /// The session in the checkout at `root`: one that lives there, else one
    /// whose shell is standing in it, else one archived there. Plain path
    /// equality: every side is a resolved path (git's listing,
    /// `GitWorktree.Linked.root`, and the checkout an archived session was
    /// recorded with), and this runs while a list draws.
    static func sessionName(at root: String, live: [Live], archived: [Archived]) -> String? {
        live.first { $0.home == root }?.name
            ?? live.first { $0.visiting == root }?.name
            ?? archived.first { $0.checkout == root }?.name
    }

    /// The name to show for the checkout at `path`.
    static func title(path: String, sessionName: String?, branch: String?, isPrimary: Bool) -> String {
        let folder = (path as NSString).lastPathComponent
        if let sessionName, !sessionName.isEmpty { return sessionName }
        if isPrimary { return folder }
        if let branch, !branch.isEmpty { return branch }
        return folder
    }
}
