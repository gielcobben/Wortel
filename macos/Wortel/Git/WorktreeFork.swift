import Foundation

/// Fork Session's half that is git: everything uncommitted in a checkout,
/// taken the moment Fork is pressed, and put back into a new worktree made at
/// the same commit.
///
/// What a fork means is "this, as it is right now, somewhere I can try
/// something else", so the new worktree starts at the source's HEAD, not at
/// trunk, and carries its staged changes, its unstaged changes and its
/// untracked files, each kept as what it was: staged stays staged. Other tools
/// stop short of this. A conversation fork carries the conversation and leaves
/// the files behind; a branch from HEAD leaves the uncommitted work behind.
///
/// **The source is never touched.** No `git stash`, which rewrites the
/// source's index under an agent that may be running git there, and drops
/// untracked files: two binary diffs read under `GIT_OPTIONAL_LOCKS=0`
/// (`GitService.gitEnvironment`), plus untracked files cloned into a staging
/// folder on the same volume, so the snapshot is frozen at the press while
/// the agent in the source keeps writing.
enum WorktreeFork {
    /// git's empty tree, the base of a diff in a repository with no commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Where untracked files wait between the press and the new worktree.
    /// Not under `GitWorktree.root`: everything there is taken for a worktree
    /// by `WorktreeCleanup.folders`.
    static var stagingRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".wortel/staging", isDirectory: true)
    }

    /// Patches past this aren't carried: something generated got into the
    /// working tree, and the fork would take minutes to apply it.
    static let patchLimit = 1 << 30

    /// What `git status --porcelain=v2 -z --no-renames` says the snapshot
    /// needs to know.
    struct Status: Equatable {
        var unmerged = false
        var untracked: [String] = []
        /// Paths with a change in the work tree (the status's second column).
        var unstaged: [String] = []
        /// Every path with any change, staged or not, for the fallback copy.
        var changed: [String] = []
    }

    static func parseStatus(_ data: Data) -> Status {
        var status = Status()
        for entry in data.split(separator: 0) {
            let line = String(decoding: entry, as: UTF8.self)
            guard let kind = line.first else { continue }
            switch kind {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let path = String(fields[8])
                status.changed.append(path)
                if fields[1].count == 2, fields[1].last != "." { status.unstaged.append(path) }
            case "u":
                status.unmerged = true
            case "?":
                status.untracked.append(String(line.dropFirst(2)))
            default:
                continue // headers, ignored entries; renames are off
            }
        }
        return status
    }

    /// The uncommitted state of one checkout, frozen.
    final class Snapshot: Equatable {
        /// The checkout it came from.
        let sourceRoot: String
        /// The commit the new worktree is made at; nil in a repository with
        /// none yet, where the new branch is an orphan.
        let head: String?
        let staged: Data
        let unstaged: Data
        /// The untracked files, cloned under `staging` at their own paths.
        let staging: URL?
        let untracked: [String]
        /// Every changed path, for the fallback copy.
        let changed: [String]
        /// Notes from taking it (an untracked file too big to carry).
        let warnings: [String]

        init(sourceRoot: String, head: String?, staged: Data, unstaged: Data, staging: URL?,
             untracked: [String], changed: [String], warnings: [String]) {
            self.sourceRoot = sourceRoot
            self.head = head
            self.staged = staged
            self.unstaged = unstaged
            self.staging = staging
            self.untracked = untracked
            self.changed = changed
            self.warnings = warnings
        }

        static func == (a: Snapshot, b: Snapshot) -> Bool { a === b }

        /// Whether there is anything to carry at all.
        var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }

        /// Drop the staging folder: the fork is done with it, or never will be.
        func discard() {
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
    }

    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The diff options both patches share: binary-safe, no external diff or
    /// textconv (which would put something other than the bytes in the
    /// patch), no rename detection (a rename is a delete and an add, which
    /// applies everywhere), fixed prefixes whatever the user's config says.
    private static let diffOptions = [
        "-c", "diff.noprefix=false", "diff", "--binary", "--no-color", "--no-ext-diff",
        "--no-textconv", "--no-renames", "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/",
    ]

    /// Snapshot the checkout `root`. Read-only on it. `named` is the session,
    /// for the refusals; `stagingRoot` is where untracked files wait (the
    /// tests' own, so they never touch the real one).
    static func snapshot(of root: String, named name: String,
                         stagingRoot: URL = stagingRoot) async -> Result<Snapshot, Refusal> {
        let headResult = await GitService.run(["rev-parse", "--verify", "-q", "HEAD"], in: root)
        let head = headResult.ok ? headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let status = parseStatus(await GitService.runData(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"], in: root))
        if status.unmerged {
            return .failure(Refusal(message: """
                \u{201c}\(name)\u{201d} is in the middle of a merge. Finish it there, then fork.
                """))
        }
        let staged = await GitService.runData(
            diffOptions + ["--cached", head ?? emptyTree], in: root)
        var unstaged = Data()
        if !status.unstaged.isEmpty {
            for chunk in GitService.chunked(status.unstaged) {
                unstaged += await GitService.runData(diffOptions + ["--"] + chunk, in: root)
            }
        }
        if staged.count + unstaged.count > patchLimit {
            return .failure(Refusal(message: "These changes are too big to carry over (over 1 GB)."))
        }
        var staging: URL?
        var report = WorktreeInclude.Report()
        if !status.untracked.isEmpty {
            let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            WorktreeInclude.copy(status.untracked.map { WorktreeInclude.Item(path: $0, isDirectory: false) },
                                 from: root, to: folder.path, into: &report)
            staging = folder
        }
        return .success(Snapshot(sourceRoot: root, head: head, staged: staged, unstaged: unstaged,
                                 staging: staging, untracked: status.untracked,
                                 changed: status.changed, warnings: report.warnings))
    }

    /// Put `snapshot` into the new worktree at `path`, made at its HEAD.
    /// Returns warnings, or a refusal when even the fallback failed.
    static func apply(_ snapshot: Snapshot, to path: String) async -> Result<[String], Refusal> {
        var warnings = snapshot.warnings
        var applied = true
        if !snapshot.staged.isEmpty {
            applied = await GitService.run(["apply", "--index", "--binary", "--whitespace=nowarn", "-"],
                                           in: path, input: snapshot.staged).ok
        }
        if applied, !snapshot.unstaged.isEmpty {
            applied = await GitService.run(["apply", "--binary", "--whitespace=nowarn", "-"],
                                           in: path, input: snapshot.unstaged).ok
        }
        if !applied {
            // LFS pointers, a filter, a mode git won't set: put the bytes there
            // instead. The worktree is new and holds only what git just checked
            // out, so starting it over from HEAD loses nothing.
            _ = await GitService.run(["checkout", "-f", "HEAD", "--", "."], in: path)
            _ = await GitService.run(["clean", "-fdq"], in: path)
            guard copyChangedFiles(snapshot.changed, from: snapshot.sourceRoot, to: path) else {
                return .failure(Refusal(message: "The changes couldn't be carried over, as a patch or as files."))
            }
            warnings.append("""
                The changes didn't apply as a patch, so the changed files were copied instead. \
                They're all unstaged here.
                """)
        }
        if let staging = snapshot.staging {
            var skipped = 0
            for file in snapshot.untracked {
                let from = staging.appendingPathComponent(file)
                let to = URL(fileURLWithPath: path).appendingPathComponent(file)
                guard (try? from.checkResourceIsReachable()) == true || isSymlink(from.path) else { continue }
                if FileManager.default.fileExists(atPath: to.path) { skipped += 1; continue }
                try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                if (try? FileManager.default.moveItem(at: from, to: to)) == nil { skipped += 1 }
            }
            if skipped > 0 { warnings.append("\(skipped) untracked files weren't carried over.") }
        }
        snapshot.discard()
        return .success(warnings)
    }

    /// The fallback: each changed path's bytes as they are in the source now,
    /// and each path the source deleted, deleted. Unstaged, all of it.
    private static func copyChangedFiles(_ paths: [String], from source: String, to target: String) -> Bool {
        var ok = true
        for path in paths {
            let from = source + "/" + path
            let to = target + "/" + path
            if FileManager.default.fileExists(atPath: from) || isSymlink(from) {
                try? FileManager.default.removeItem(atPath: to)
                try? FileManager.default.createDirectory(
                    atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_NOFOLLOW)) != 0 {
                    ok = false
                }
            } else {
                try? FileManager.default.removeItem(atPath: to)
            }
        }
        return ok
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// The fork's branch: Wortel's namespace (so Clean Up may delete it), the
    /// source branch's name without the namespace or an earlier `-fork-xxxx`,
    /// and four hex digits, walked until free.
    static func branchName(forking source: String?, taken: Set<String>,
                           seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> String {
        var stem = source ?? ""
        if stem.hasPrefix(GitWorktree.branchNamespace) { stem.removeFirst(GitWorktree.branchNamespace.count) }
        if let range = stem.range(of: #"-fork-[0-9a-f]{4}$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        stem = GitWorktree.branchName(from: stem.replacingOccurrences(of: "/", with: "-"))
        var value = seed
        while true {
            let suffix = String(format: "%04x", value & 0xffff)
            let name = GitWorktree.branchNamespace + (stem.isEmpty ? "fork-\(suffix)" : "\(stem)-fork-\(suffix)")
            if !taken.contains(name) { return name }
            value = value &* 6364136223846793005 &+ 1442695040888963407
        }
    }
}
