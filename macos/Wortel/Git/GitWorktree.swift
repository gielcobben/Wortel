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
    /// `git worktree lock`ed: someone said not to remove it. Cleanup respects it.
    var isLocked = false
    /// The commit checked out. For a detached HEAD this is the only thing
    /// holding its commits, so cleanup has to know it.
    var head: String?
    /// Its folder is gone: git still lists it until `worktree prune`.
    var isPrunable = false
    /// The repository has no working tree of its own (a bare clone, as
    /// worktree-first tools set them up). Only ever the first entry.
    var isBare = false
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

    /// A typed name made into one git accepts: what you meant, not a refusal.
    /// "worktree/Jump to" becomes "worktree/Jump-to".
    ///
    /// GitHub Desktop's rule (`sanitizedRefName`), which VS Code's
    /// `git.branchWhitespaceChar` default agrees with: every run of what
    /// `git check-ref-format` forbids (spaces and control characters,
    /// `~ ^ : ? * [ \`, `@{`, `..`) becomes one "-". Then the rules about
    /// where things may appear: no empty or dot-led path component, none ending
    /// in `.lock`, no leading "-", no trailing "." or "/". Case is kept: it's
    /// your name. Empty when nothing usable is left; git's own check at
    /// creation is still the last word.
    static func branchName(from typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(
            of: #"[\x00-\x20\x7F~^:?*\[\\]+|@\{|\.\.+"#, with: "-", options: .regularExpression)
        let components = name.split(separator: "/", omittingEmptySubsequences: true).map { part in
            var part = String(part)
            while part.hasPrefix(".") { part.removeFirst() }
            while part.hasSuffix(".lock") { part.removeLast(".lock".count) }
            return part
        }
        name = components.filter { !$0.isEmpty }.joined(separator: "/")
        name = name.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        while name.hasPrefix("-") || name.hasPrefix("+") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix("/") { name.removeLast() }
        return name == "@" ? "" : name
    }

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
    /// The checkout `path` is inside, as the directory Wortel made for it
    /// (`~/.wortel/worktrees/<repo>/<checkout>`), whatever depth the shell has
    /// since `cd`'d to. nil outside Wortel's worktrees, and for the repository
    /// folders themselves.
    static func checkout(containing path: String?, under base: String = root.path) -> String? {
        guard let path, path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(base)/\(parts[0])/\(parts[1])"
    }

    /// The branch checked out in the worktree at `path`, read from the files
    /// git keeps there rather than by running git: its `.git` file names the
    /// worktree's own git folder, and that folder's `HEAD` names the branch.
    /// Instant, so a list of worktrees can show the right names before any
    /// git has answered. nil for a detached HEAD, a folder that isn't a
    /// linked worktree, or anything unreadable; the slower check has the
    /// last word.
    nonisolated static func checkedOutBranch(at path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              pointer.hasPrefix("gitdir:") else { return nil }
        var gitDir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDir.hasPrefix("/") { gitDir = (path as NSString).appendingPathComponent(gitDir) }
        guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                                     encoding: .utf8) else { return nil }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("ref: refs/heads/") else { return nil }
        let branch = String(ref.dropFirst("ref: refs/heads/".count))
        return branch.isEmpty ? nil : branch
    }

    /// A linked worktree, wherever it is and whoever made it: Wortel, another
    /// app, a script, or `git worktree add` by hand.
    struct Linked: Equatable {
        /// The checkout's own folder, the one holding its `.git` file.
        let root: String
        /// Where the repository lives: the primary checkout's folder, or for a
        /// bare clone set up the worktree-first way (`repo/.bare` beside
        /// `repo/main`, `repo/feature`), the folder holding it and its
        /// worktrees. nil for a bare clone anywhere else.
        let repoHome: String?
    }

    /// The linked worktree `path` is in, at any depth, read from the files git
    /// keeps rather than by running git, so it's cheap enough for every `cd`.
    ///
    /// The nearest `.git` decides. A folder is a repository's own checkout
    /// (nil); a file pointing into `<common>/worktrees/<name>` is a linked
    /// worktree. A file pointing anywhere else is a submodule, which is a
    /// repository of its own, not a worktree (nil).
    nonisolated static func linked(containing path: String) -> Linked? {
        var directory = (path as NSString).standardizingPath
        let files = FileManager.default
        while true {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue,
                      let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      pointer.hasPrefix("gitdir:") else { return nil }
                var gitDir = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !gitDir.hasPrefix("/") { gitDir = (directory as NSString).appendingPathComponent(gitDir) }
                let parts = (gitDir as NSString).standardizingPath.split(separator: "/").map(String.init)
                guard parts.count >= 3, parts[parts.count - 2] == "worktrees" else { return nil }
                let common = "/" + parts.dropLast(2).joined(separator: "/")
                let leaf = (common as NSString).lastPathComponent
                let home = leaf == ".git" || leaf == ".bare" ? (common as NSString).deletingLastPathComponent : nil
                return Linked(root: realPath(directory), repoHome: home.map(realPath))
            }
            let parent = (directory as NSString).deletingLastPathComponent
            guard parent != directory, !parent.isEmpty else { return nil }
            directory = parent
        }
    }

    /// `path` with its symlinks resolved, as git records worktrees
    /// (`/private/var/…`), where a shell reports the way it was reached
    /// (`/var/…`, or a symlinked `~/work`). Unchanged when it can't be.
    /// Not `NSString.resolvingSymlinksInPath`, which strips `/private` again.
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

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
        var locked = false
        var head: String?
        var prunable = false
        var bare = false

        func flush() {
            guard let current = path else { return }
            result.append(GitWorktree(path: current, branch: branch, isPrimary: result.isEmpty,
                                      isLocked: locked, head: head, isPrunable: prunable, isBare: bare))
            path = nil
            branch = nil
            locked = false
            head = nil
            prunable = false
            bare = false
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush() // a stanza that ran straight into the next one
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            } else if line == "bare" {
                bare = true
            }
        }
        flush()
        return result
    }
}
