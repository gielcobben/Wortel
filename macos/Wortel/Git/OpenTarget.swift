import Foundation

/// ⇧⌘O, Open Branch: one field that gets you to a branch, whatever state it's
/// in. Go to the session already there; restore the one archived there;
/// open a session in a worktree nobody's in; check a branch out in a new
/// worktree; check out a pull request; or make the branch. The same verb
/// every time, "take me to it", which is worktrunk's `switch` and lazygit's
/// one field, so nobody has to know which of those it is before asking.
///
/// This is the deciding half, pure: what's listed for what's typed, in what
/// order, and what each row does. The panel shows it (`SessionSwitcher`),
/// the manager does it.
enum OpenTarget {
    enum Action: Equatable {
        /// A live session in a worktree.
        case goTo(UUID)
        /// An archived session.
        case restore(UUID)
        /// A worktree on disk that no session is in.
        case openWorktree(path: String)
        /// The branch is the main checkout's: a session there, not a worktree.
        case mainCheckout(path: String)
        /// A branch that exists, locally or on `remote`, into a new worktree.
        case checkOut(branch: String, remote: String?)
        /// A pull request, as typed (`PullRequestRef`).
        case pullRequest(String)
        /// A new branch from the default branch, in a new worktree.
        case create(branch: String)
    }

    /// The groups, in the order they're listed.
    enum Group: Int, Comparable {
        case pullRequest, open, archived, notOpen, branches, create
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String? {
            switch self {
            case .pullRequest, .create: return nil
            case .open: return "Open"
            case .archived: return "Archived"
            case .notOpen: return "Not open"
            case .branches: return "Branches"
            }
        }
    }

    struct Choice: Identifiable, Equatable {
        let action: Action
        let group: Group
        /// The name to show: the session's, or the branch.
        let title: String
        /// The branch, when the title isn't it.
        let branch: String?
        /// What pressing Return does, in words.
        let status: String

        var id: String {
            switch action {
            case .goTo(let id), .restore(let id): return id.uuidString
            case .openWorktree(let path), .mainCheckout(let path): return "path:" + path
            case .checkOut(let branch, let remote): return "branch:\(remote ?? "")/\(branch)"
            case .pullRequest(let text): return "pr:" + text
            case .create(let branch): return "create:" + branch
            }
        }
    }

    /// What the panel knows when it opens, and what arrives after.
    struct Inputs: Equatable {
        struct Place: Equatable {
            let id: UUID
            let name: String
            let branch: String?
        }
        struct Worktree: Equatable {
            let path: String
            let branch: String?
        }
        var open: [Place] = []
        var archived: [Place] = []
        /// Archived sessions of other repositories: the sidebar doesn't show
        /// archived ones, so this is where they're found from anywhere. Their
        /// branches are another repository's, and place nothing here.
        var archivedElsewhere: [Place] = []
        var notOpen: [Worktree] = []
        /// The repository's own checkout, and the branch on it.
        var main: Worktree?
        var local: [String] = []
        /// Remote-tracking branches as (remote, branch).
        var remote: [(remote: String, branch: String)] = []
        /// Whether there's a repository to make branches in at all.
        var hasRepository = false

        static func == (a: Inputs, b: Inputs) -> Bool {
            a.open == b.open && a.archived == b.archived
                && a.archivedElsewhere == b.archivedElsewhere && a.notOpen == b.notOpen && a.main == b.main
                && a.local == b.local && a.hasRepository == b.hasRepository
                && a.remote.map { "\($0.remote)/\($0.branch)" } == b.remote.map { "\($0.remote)/\($0.branch)" }
        }
    }

    /// Rows past this many branches aren't listed: the field narrows them.
    static let branchLimit = 30

    static func choices(for query: String, in inputs: Inputs) -> [Choice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Choice] = []
        // A branch that already has a place (a session, an archive, a
        // worktree, the main checkout) is listed there, once.
        var placed = Set<String>()

        func matches(_ fields: String?...) -> Bool {
            guard !query.isEmpty else { return true }
            let haystack = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
            return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
        }

        if !query.isEmpty, inputs.hasRepository,
           let pr = PullRequestRef.parse(query, allowsBareNumber: !inputs.local.contains(query)
                                            && !inputs.remote.contains { $0.branch == query }) {
            result.append(Choice(action: .pullRequest(query), group: .pullRequest,
                                 title: "Pull request \(pr.label)", branch: nil,
                                 status: "Checks out pull request \(pr.label) in a new worktree."))
        }
        for place in inputs.open {
            if let branch = place.branch { placed.insert(branch) }
            guard matches(place.name, place.branch) else { continue }
            result.append(Choice(action: .goTo(place.id), group: .open, title: place.name, branch: place.branch,
                                 status: "Goes to the session."))
        }
        for place in inputs.archived {
            if let branch = place.branch { placed.insert(branch) }
            guard matches(place.name, place.branch) else { continue }
            result.append(Choice(action: .restore(place.id), group: .archived, title: place.name,
                                 branch: place.branch, status: "Restores the session, agent and all."))
        }
        for place in inputs.archivedElsewhere where matches(place.name, place.branch) {
            result.append(Choice(action: .restore(place.id), group: .archived, title: place.name,
                                 branch: place.branch, status: "Restores the session, agent and all."))
        }
        for worktree in inputs.notOpen {
            if let branch = worktree.branch { placed.insert(branch) }
            let name = worktree.branch ?? (worktree.path as NSString).lastPathComponent
            guard matches(name, worktree.path) else { continue }
            result.append(Choice(action: .openWorktree(path: worktree.path), group: .notOpen, title: name,
                                 branch: nil, status: "Opens a session in its worktree."))
        }
        // Nothing typed: what's open and put away, not every branch there is.
        guard !query.isEmpty else { return result }

        var branches: [Choice] = []
        if let main = inputs.main, let branch = main.branch, !placed.contains(branch) {
            placed.insert(branch)
            if matches(branch) {
                branches.append(Choice(action: .mainCheckout(path: main.path), group: .branches, title: branch,
                                       branch: nil,
                                       status: "\u{201c}\(branch)\u{201d} is checked out in your main folder. This opens a session there."))
            }
        }
        for branch in inputs.local where !placed.contains(branch) && matches(branch) {
            branches.append(Choice(action: .checkOut(branch: branch, remote: nil), group: .branches, title: branch,
                                   branch: nil, status: "Checks out \u{201c}\(branch)\u{201d} in a new worktree."))
        }
        let local = Set(inputs.local)
        var seenRemote = Set<String>()
        for (remote, branch) in inputs.remote
        where !local.contains(branch) && !placed.contains(branch) && matches(branch, "\(remote)/\(branch)")
            && seenRemote.insert(branch).inserted {
            branches.append(Choice(action: .checkOut(branch: branch, remote: remote), group: .branches,
                                   title: branch, branch: nil,
                                   status: "Checks out \u{201c}\(branch)\u{201d} from \(remote) in a new worktree."))
        }
        // The closest first: a branch that starts with what's typed.
        let lower = query.lowercased()
        branches = branches.enumerated().sorted { a, b in
            let pa = a.element.title.lowercased().hasPrefix(lower), pb = b.element.title.lowercased().hasPrefix(lower)
            return pa != pb ? pa : a.offset < b.offset
        }.map(\.element)
        result += branches.prefix(branchLimit)

        // Always offered while what's typed would be a new branch.
        let name = GitWorktree.branchName(from: query)
        // `origin/foo` typed or pasted is the remote branch, never a new
        // local one wearing its name.
        let exists = local.contains(name)
            || inputs.remote.contains { $0.branch == name || "\($0.remote)/\($0.branch)" == name }
            || placed.contains(name) || inputs.main?.branch == name
        if inputs.hasRepository, !name.isEmpty, !exists, result.first?.group != .pullRequest {
            result.append(Choice(action: .create(branch: name), group: .create,
                                 title: "Create \u{201c}\(name)\u{201d}", branch: nil,
                                 status: "Creates \u{201c}\(name)\u{201d} from the default branch, in a new worktree."))
        }
        return result
    }
}
