import Foundation

/// What ⌘P lists besides the open sessions: the places a session can be
/// brought back to. An archived session (closing a worktree session puts it
/// away, agent and all) and a worktree on disk no session is in. The sidebar
/// shows neither, so typing in ⌘P is how they're found.
///
/// This used to be Open Branch (⇧⌘O), which also checked out branches and
/// pull requests and made new ones; that is the New Worktree sheet's now, and
/// this kept only the half that finds what's already there.
///
/// Pure: what's listed for what's typed, and what Return does. The panel
/// shows it (`SessionSwitcher`), the manager does it.
enum OpenTarget {
    enum Action: Equatable {
        /// An archived session.
        case restore(UUID)
        /// A worktree on disk that no session is in.
        case openWorktree(path: String)
    }

    /// The groups, in the order they're listed.
    enum Group: Int, Comparable {
        case archived, notOpen
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .archived: return "Archived"
            case .notOpen: return "Not open"
            }
        }
    }

    struct Choice: Identifiable, Equatable {
        let action: Action
        let group: Group
        /// The name to show: the session's, or the branch.
        let title: String
        /// What sits beside the title: an archived session's branch, or the
        /// repository a worktree is of (two can have a worktree on the same
        /// branch name).
        let detail: String?
        /// What pressing Return does, in words.
        let status: String

        var id: String {
            switch action {
            case .restore(let id): return id.uuidString
            case .openWorktree(let path): return "path:" + path
            }
        }
    }

    struct Inputs: Equatable {
        struct Place: Equatable {
            let id: UUID
            let name: String
            let branch: String?
        }
        struct Worktree: Equatable {
            let path: String
            let branch: String?
            /// The repository, as a path with `~` for home: two called `app`
            /// in different places are still two.
            var repository: String? = nil
        }
        var archived: [Place] = []
        var notOpen: [Worktree] = []
    }

    /// Only for something typed: with nothing typed ⌘P is the recent
    /// sessions, and every worktree ever put away under them would bury them.
    /// Every word typed has to be in the name, the branch, the repository or
    /// the path.
    static func choices(for query: String, in inputs: Inputs) -> [Choice] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        func matches(_ fields: String?...) -> Bool {
            let haystack = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
            return words.allSatisfy { haystack.contains($0) }
        }
        var result: [Choice] = []
        for place in inputs.archived where matches(place.name, place.branch) {
            result.append(Choice(action: .restore(place.id), group: .archived, title: place.name,
                                 detail: place.branch, status: "Restores the session, agent and all."))
        }
        for worktree in inputs.notOpen {
            let name = worktree.branch ?? (worktree.path as NSString).lastPathComponent
            guard matches(name, worktree.repository, worktree.path) else { continue }
            result.append(Choice(action: .openWorktree(path: worktree.path), group: .notOpen, title: name,
                                 detail: worktree.repository, status: "Opens a session in its worktree."))
        }
        return result
    }
}
