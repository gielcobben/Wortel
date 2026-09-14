import Foundation

/// A git worktree: a second checkout of one repository, on its own branch, in
/// its own directory, sharing a single `.git`.
///
/// This is the answer to the thing that makes several agents in one repo a
/// footgun — they share a working tree, so two of them editing at once is two
/// of them editing the same files, and switching branches under a running agent
/// changes the ground beneath it mid-task. A worktree per session gives each one
/// its own branch and its own files, at the cost of a directory rather than a
/// clone: history, remotes and objects stay shared.
///
/// The path derivation and the porcelain parsing live here, apart from the
/// commands, because both are string handling with silent failure modes — a slug
/// that collides puts two branches in one directory, and a mis-parsed listing
/// makes an existing worktree invisible so the next attempt tries to create it
/// again and fails.
struct GitWorktree: Equatable {
    /// The checkout's directory.
    let path: String
    /// The branch checked out there, short name. nil for a detached HEAD.
    let branch: String?
    /// The repository's own working tree — the one that isn't a linked worktree.
    let isPrimary: Bool
}

extension GitWorktree {
    /// Where Wortel keeps the worktrees it creates: outside the repository, so
    /// they can never be committed, never confuse a build that walks the project,
    /// and never disappear when the branch they belong to is deleted.
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".wortel/worktrees", isDirectory: true)
    }

    /// The namespace every branch Wortel generates lives in (`BranchSheet`
    /// suggests `worktree/<adjective>-<noun>-<hex>`). It exists to group them
    /// under one heading in `git branch`, where they are disposable and you will
    /// want to sweep them later. One constant, because the half that makes the
    /// name and the half that reads it back must never drift apart.
    static let branchNamespace = "worktree/"

    /// What a worktree session is called in the sidebar before an agent says
    /// what it is for: the branch, minus Wortel's own namespace.
    ///
    /// The prefix is on every branch the app makes, so in a sidebar where every
    /// one of these rows carries it, it distinguishes nothing. A namespace you
    /// chose yourself (`fix/login`) is kept: there it is the half that says what
    /// the branch is for.
    ///
    /// Whatever survives is made slash-free (`SessionName.asLeaf`), and that is
    /// the point of this existing at all. A session's folder is the part of its
    /// name before the last slash, so a branch dropped in whole filed its
    /// session under a folder named for the branch's namespace — a second,
    /// sibling group in the sidebar holding exactly the sessions that belong in
    /// the first one. Every other automatic name already passes through
    /// `asLeaf`; this was the one path that did not.
    static func sessionLeaf(forBranch branch: String) -> String {
        guard branch.hasPrefix(branchNamespace) else { return SessionName.asLeaf(branch) }
        let stripped = branch.dropFirst(branchNamespace.count)
        // A branch that is nothing but the namespace has no leaf to show, and an
        // empty row is worse than a redundant one.
        return SessionName.asLeaf(stripped.isEmpty ? branch : String(stripped))
    }

    /// A worktree session's name with the phantom folder an earlier build gave
    /// it removed, or nil when there is nothing to repair.
    ///
    /// Until `sessionLeaf` above, a worktree session was named
    /// "<folder>/<branch>" with the branch whole, so `GFPC` plus
    /// `worktree/wakker-slide` became a session called `wakker-slide` in a
    /// folder called `GFPC/worktree`. The agent rename that followed kept the
    /// folder half (only the leaf changes), which is why the phantom folder
    /// outlives the placeholder that made it and has to be undone here rather
    /// than just stopped.
    ///
    /// Only the branch's own namespace is stripped, and only from the end of the
    /// folder, so a folder someone deliberately named "worktree" for unrelated
    /// sessions is untouched: those sessions have no branch to match it against.
    static func repairedSessionName(_ name: String, branch: String) -> String? {
        let namespace = (branch as NSString).deletingLastPathComponent
        guard !namespace.isEmpty, let folder = SessionName.folder(of: name) else { return nil }
        let leaf = SessionName.leaf(of: name)
        if folder == namespace { return leaf }
        guard folder.hasSuffix("/" + namespace) else { return nil }
        return String(folder.dropLast(namespace.count + 1)) + "/" + leaf
    }

    /// A branch name as one path component. Branch names may contain slashes
    /// (`feature/preview-window`), which would otherwise nest directories, and
    /// characters a path shouldn't carry.
    ///
    /// Collisions matter more than beauty here, and simply replacing the awkward
    /// characters isn't enough: `feature/x` and `feature-x` are *different
    /// branches* that both flatten to `feature-x`, and one directory for two
    /// branches means the second session silently lands in the first one's
    /// files. (A test caught exactly that.)
    ///
    /// So a name that is already a safe path component is used verbatim — branch
    /// names are unique, so those can't collide — and only a name that had to be
    /// rewritten carries a short digest of the original, which restores the
    /// distinction the rewrite destroyed. `main` stays `main`; `feature/x`
    /// becomes `feature-x-<digest>`.
    static func slug(forBranch branch: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let isSafe = !branch.isEmpty
            && branch.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !branch.hasPrefix("-") && !branch.hasPrefix(".")
            && !branch.hasSuffix("-") && !branch.hasSuffix(".")
        if isSafe { return branch }

        let mapped = branch.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = trimmed.isEmpty ? "worktree" : trimmed
        return "\(stem)-\(digest(branch))"
    }

    /// FNV-1a, and hand-written for one reason: the path has to be the *same
    /// path* next launch. Swift's `hashValue` is seeded per process, so a
    /// worktree keyed on it would be unfindable the moment the app restarts.
    private static func digest(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in Array(text.utf8) {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%06x", hash & 0xFF_FFFF)
    }

    /// `~/.wortel/worktrees/<repo>/<branch-slug>`. The repository's own directory
    /// name groups them, so two projects with a `main` branch don't collide and
    /// the folder is readable when you go looking.
    static func path(forBranch branch: String, repoRoot: String) -> String {
        let repo = (repoRoot as NSString).lastPathComponent
        return root
            .appendingPathComponent(slug(forBranch: repo), isDirectory: true)
            .appendingPathComponent(slug(forBranch: branch), isDirectory: true)
            .path
    }

    /// Parse `git worktree list --porcelain`.
    ///
    /// The format is stanzas separated by blank lines: a `worktree <path>` line,
    /// then optionally `HEAD <sha>`, then either `branch refs/heads/<name>` or
    /// `detached`. The first stanza is always the primary working tree.
    static func parse(porcelain: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var path: String?
        var branch: String?

        func flush() {
            guard let current = path else { return }
            result.append(GitWorktree(path: current, branch: branch, isPrimary: result.isEmpty))
            path = nil
            branch = nil
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush() // a stanza that ran straight into the next one
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return result
    }
}
