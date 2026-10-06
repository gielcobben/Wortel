import Foundation

/// One worktree Wortel made, and what removing it would cost.
///
/// The cleanup's whole rule is that nothing holding work you can't get back is
/// removed without you choosing it. So every worktree is inspected first and
/// lands in one of three verdicts, and the sheet only ever offers what the
/// verdict allows:
///
/// - **safe**: no uncommitted or untracked files, and every commit on its
///   branch is also on another branch or a remote. Removing the folder *and*
///   the branch loses nothing. (Or the folder is already gone and only git's
///   registration is left.)
/// - **keepsCommits**: clean, but the branch has commits found nowhere else.
///   The folder can go; the branch stays unless you explicitly say otherwise.
/// - **blocked**: uncommitted changes, something running in it, another session
///   open in it, a lock, or a folder that isn't a checkout any more. Nothing is
///   offered, and the reasons say what to do.
///
/// Folders go to the Trash rather than being deleted. Even a clean worktree
/// holds files git doesn't track and can't vouch for (an `.env` copied in by
/// hand is ignored, so a clean status says nothing about it), and the Trash is
/// what makes "nothing lost" true for those as well.
struct WorktreeReport: Identifiable, Equatable, Sendable {
    let path: String
    /// The primary checkout: it owns the registration and the branch. nil when
    /// the folder isn't a git checkout any more.
    var repoRoot: String?
    var branch: String?
    /// The folder is gone; only git's registration of it is left.
    var isMissing = false
    /// The folder exists but git doesn't know it as a checkout any more.
    var isOrphanedFolder = false
    var isLocked = false
    /// Uncommitted and untracked files, repo-relative.
    var changedFiles: [String] = []
    /// Commits on the branch (or a detached HEAD) that no other branch or
    /// remote has: the ones deleting the branch would lose. nil when git
    /// couldn't say, which is treated as "there may be some".
    var uniqueCommits: Int? = 0
    /// What is using it right now, as a reader would say it: "the session
    /// “fix login”", "node".
    var usedBy: [String] = []

    var id: String { path }

    enum Verdict: Equatable, Sendable {
        case safe
        case keepsCommits
        case blocked
    }

    var verdict: Verdict {
        if isMissing { return .safe }
        if isOrphanedFolder || isLocked || !changedFiles.isEmpty || !usedBy.isEmpty {
            return .blocked
        }
        return uniqueCommits == 0 ? .safe : .keepsCommits
    }

    /// Whether Wortel may offer to delete the branch at all. Only a branch in
    /// its own namespace: a branch you checked out into a worktree yourself is
    /// yours, and removing the folder you looked at it in says nothing about
    /// wanting it gone.
    var ownsBranch: Bool {
        branch?.hasPrefix(GitWorktree.branchNamespace) == true
    }

    /// The folder's name, which is what the worktree is called on disk.
    var folderName: String { (path as NSString).lastPathComponent }

    /// The repository it belongs to, by folder name.
    var repoName: String? { repoRoot.map { ($0 as NSString).lastPathComponent } }

    /// Why it can't be removed, one sentence each. Empty unless blocked.
    var blockers: [String] {
        var reasons: [String] = []
        if isOrphanedFolder {
            reasons.append("This folder isn't a git checkout any more, so Wortel can't tell what's in it. Check it in Finder.")
        }
        if isLocked { reasons.append("It's locked in git (git worktree lock).") }
        if !changedFiles.isEmpty {
            let count = changedFiles.count
            let named = changedFiles.prefix(3).joined(separator: ", ")
            let more = count > 3 ? " and \(count - 3) more" : ""
            reasons.append("\(count) uncommitted change\(count == 1 ? "" : "s"): \(named)\(more).")
        }
        for user in usedBy {
            reasons.append("In use by \(user).")
        }
        return reasons
    }

    /// One line on what removing it does, for the safe and keepsCommits cases.
    var summary: String {
        if isMissing { return "Its folder is already gone. Only git's record of it is left." }
        switch verdict {
        case .safe:
            return "No uncommitted changes, and its commits are on other branches."
        case .keepsCommits:
            guard let n = uniqueCommits else {
                return "Wortel couldn't tell whether its commits are anywhere else, so the branch is kept."
            }
            return "\(n) commit\(n == 1 ? "" : "s") only on this branch. The branch is kept unless you choose otherwise."
        case .blocked:
            return blockers.joined(separator: " ")
        }
    }
}

enum WorktreeCleanup {
    /// Every worktree Wortel made: the folders under `GitWorktree.root`, plus
    /// any registration under it whose folder is gone, found through the
    /// repositories those folders (and `knownRepos`, the repos open sessions
    /// are in) belong to.
    static func discover(knownRepos: [String] = [], under base: URL = GitWorktree.root) async -> [String] {
        let fm = FileManager.default
        let root = base.path
        var found: [String] = []
        for repoDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let repoPath = (root as NSString).appendingPathComponent(repoDir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: repoPath, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            for entry in (try? fm.contentsOfDirectory(atPath: repoPath)) ?? [] {
                let path = (repoPath as NSString).appendingPathComponent(entry)
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    found.append(path)
                }
            }
        }

        // Registrations whose folder is gone. Only through repos we can name:
        // the ones the folders above belong to, and the ones sessions are in.
        var repos = Set(knownRepos)
        for path in found {
            if let primary = await primaryCheckout(of: path) { repos.insert(primary) }
        }
        for repo in repos {
            for worktree in await GitService.worktrees(root: repo)
            where !worktree.isPrimary && isUnder(base, worktree.path)
                && !fm.fileExists(atPath: worktree.path) {
                found.append(worktree.path)
            }
        }
        return Array(Set(found)).sorted()
    }

    /// Inspect one worktree. `usedBy` is what the app knows is using it (open
    /// sessions, processes whose directory is inside it); it can't be found
    /// from git, so the caller supplies it.
    static func inspect(path: String, knownRepos: [String] = [], usedBy: [String] = []) async -> WorktreeReport {
        var report = WorktreeReport(path: path)
        guard FileManager.default.fileExists(atPath: path) else {
            report.isMissing = true
            report.repoRoot = await registeringRepo(of: path, among: knownRepos)
            return report
        }
        guard let primary = await primaryCheckout(of: path),
              let entry = await GitService.worktrees(root: primary).first(where: { samePath($0.path, path) })
        else {
            report.isOrphanedFolder = true
            return report
        }
        report.repoRoot = primary
        report.branch = entry.branch
        report.isLocked = entry.isLocked
        report.usedBy = usedBy

        // The full scan, untracked files included: an untracked file is
        // exactly the work a "clean" status would otherwise miss.
        let status = await GitService.backgroundStatus(root: path)
        report.changedFiles = status.changes.map(\.path)

        report.uniqueCommits = await uniqueCommits(branch: entry.branch, in: path, primary: primary)
        return report
    }

    /// Remove a worktree, re-checking first: the sheet may have been open a
    /// while, and an agent may have written a file since. Returns nil on
    /// success, or why nothing was removed.
    ///
    /// `deleteBranch` is honoured only for a branch in Wortel's namespace, and
    /// for one with commits found nowhere else only when the report it was
    /// chosen against said so (`allowLosingCommits`). `discard` moves the
    /// folder away; the app passes the Trash, the tests a plain delete.
    static func remove(
        path: String, knownRepos: [String] = [], usedBy: [String] = [],
        deleteBranch: Bool, allowLosingCommits: Bool = false,
        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async -> String? {
        let report = await inspect(path: path, knownRepos: knownRepos, usedBy: usedBy)
        if report.verdict == .blocked {
            return "Kept: " + report.blockers.joined(separator: " ")
        }
        guard let primary = report.repoRoot else {
            return "Kept: Wortel couldn't find the repository it belongs to."
        }
        if !report.isMissing {
            do {
                try discard(URL(fileURLWithPath: path))
            } catch {
                return "Couldn't move the folder to the Trash: \(error.localizedDescription)"
            }
        }
        // The folder is gone now, so this only drops git's registration of it,
        // and only this one, unlike `worktree prune`, which would also forget a
        // worktree on a volume that simply isn't mounted.
        let unregistered = await GitService.run(["worktree", "remove", path], in: primary)
        if !unregistered.ok {
            let message = unregistered.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The folder is in the Trash, but git still lists it: \(message)"
        }
        if deleteBranch, report.ownsBranch, let branch = report.branch,
           report.uniqueCommits == 0 || allowLosingCommits,
           await GitService.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: primary).ok {
            // (A branch with no commits yet has no ref to delete.)
            // `-D`: `-d` asks whether the branch is merged into *HEAD*, which a
            // branch that was pushed and merged elsewhere isn't, and refuses.
            // What `-d` protects is checked above, and more precisely.
            let deleted = await GitService.run(["branch", "-D", branch], in: primary)
            if !deleted.ok {
                let message = deleted.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "The worktree is removed, but its branch isn't: \(message)"
            }
        }
        removeEmptyRepoFolder(containing: path)
        return nil
    }

    // MARK: - Helpers

    /// Commits reachable from the worktree's branch (or its detached HEAD) and
    /// from no other branch or remote-tracking branch.
    /// nil when git can't answer. A branch with no commits yet (an unborn
    /// branch, in a repository that has none) answers 0: there is nothing on it
    /// to lose.
    static func uniqueCommits(branch: String?, in path: String, primary: String) async -> Int? {
        let args: [String]
        if let branch {
            // `--exclude` patterns for `--branches` are matched without the
            // `refs/heads/` prefix; with it, they silently exclude nothing and
            // every commit counts as shared with the branch itself.
            args = ["rev-list", "--count", "refs/heads/\(branch)", "--not",
                    "--exclude=\(branch)", "--branches", "--remotes"]
        } else {
            args = ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"]
        }
        let result = await GitService.run(args, in: branch == nil ? path : primary)
        guard result.ok else {
            let hasHead = await GitService.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: path).ok
            return hasHead ? nil : 0
        }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The primary checkout a linked worktree belongs to, from git's common dir.
    static func primaryCheckout(of path: String) async -> String? {
        let result = await GitService.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        guard result.ok else { return nil }
        let common = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return nil }
        // A primary with a work tree keeps it in `<root>/.git`; a bare
        // repository *is* its common dir, and git runs fine from there.
        return (common as NSString).lastPathComponent == ".git"
            ? (common as NSString).deletingLastPathComponent : common
    }

    private static func registeringRepo(of path: String, among repos: [String]) async -> String? {
        for repo in repos {
            let worktrees = await GitService.worktrees(root: repo)
            if worktrees.contains(where: { samePath($0.path, path) }) { return repo }
        }
        return nil
    }

    static func isUnder(_ base: URL, _ path: String) -> Bool {
        canonical(path).hasPrefix(canonical(base.path) + "/") || path.hasPrefix(base.path + "/")
    }

    /// The same directory, whatever symlinks either spelling went through
    /// (`/var` against `/private/var`, mostly).
    static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || canonical(a) == canonical(b)
    }

    /// The path with symlinks resolved, for a path that may not exist. Foundation
    /// only resolves what's on disk, and a deleted worktree's folder isn't, so
    /// `/var/…/gone` never matched git's `/private/var/…/gone`: resolve the
    /// deepest part that exists and put the rest back on.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in rest { resolved.appendPathComponent(component) }
        return resolved.path
    }

    /// `~/.wortel/worktrees/<repo>` once its last worktree has gone: an empty
    /// folder is a trace too. Only if empty (a Finder `.DS_Store` aside).
    private static func removeEmptyRepoFolder(containing path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        guard isUnder(GitWorktree.root, path) else { return }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: parent)) ?? ["?"]
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? fm.removeItem(atPath: parent)
    }

    /// Repo folders under the root with nothing left in them.
    static func removeEmptyRepoFolders(under base: URL = GitWorktree.root) {
        let fm = FileManager.default
        let root = base.path
        for repoDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = (root as NSString).appendingPathComponent(repoDir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let contents = try? fm.contentsOfDirectory(atPath: path),
                  contents.allSatisfy({ $0 == ".DS_Store" })
            else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
