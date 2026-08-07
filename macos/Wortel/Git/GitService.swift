import Foundation

/// Stateless async wrapper around the `git` CLI. Every call runs the process on
/// a background queue and resumes on the caller's async context, so nothing here
/// ever blocks the main thread. Callers (the @MainActor models) marshal results
/// back themselves — same discipline as the libghostty callbacks.
enum GitService {
    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Run `git <args>` with `directory` as the working directory. Non-blocking:
    /// the Process runs on a global queue; stdout/stderr are drained
    /// concurrently so a large diff on stdout can't deadlock against stderr.
    ///
    /// `input`, when given, is written to the child's stdin and the pipe closed —
    /// for the commands that take a list there rather than as arguments
    /// (`check-ignore --stdin`). It's written from its own thread alongside the
    /// two readers, because a list long enough to fill the pipe buffer would
    /// otherwise block us while the child is blocked writing output nobody is
    /// draining yet.
    static func run(_ args: [String], in directory: String, input: Data? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                // Never let git block on a credential/terminal prompt, and don't
                // let it take the index.lock just to read status.
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe = input.map { _ in Pipe() }
                if let inPipe { process.standardInput = inPipe }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(
                        status: -1, stdout: "", stderr: "\(error)"))
                    return
                }

                // Drain both pipes off separate threads before waiting, so a
                // full pipe buffer never wedges the child.
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                if let inPipe, let input {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The close is what tells git the list is finished; without
                        // it `--stdin` waits forever. try? because a child that
                        // exited early (a bad argument) leaves us writing to a
                        // broken pipe, which is a failed command, not a crash.
                        try? inPipe.fileHandleForWriting.write(contentsOf: input)
                        try? inPipe.fileHandleForWriting.close()
                        group.leave()
                    }
                }
                process.waitUntilExit()
                group.wait()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    // MARK: - Queries

    /// The work-tree root containing `cwd`, or nil if `cwd` isn't in a repo.
    static func repoRoot(for cwd: String) async -> String? {
        let result = await run(["rev-parse", "--show-toplevel"], in: cwd)
        guard result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Recent commit subject lines (newest first) — fed to the message drafter as
    /// house-style examples so its output matches the repo's voice and any area
    /// prefix convention. Empty on a repo with no commits yet.
    static func recentCommitSubjects(root: String, limit: Int = 15) async -> [String] {
        let result = await run(["log", "-n", "\(limit)", "--format=%s"], in: root)
        guard result.ok else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Commit history for the History pane, newest first.
    ///
    /// Fields are separated by US (0x1f) and records by RS (0x1e) rather than by
    /// spaces/newlines, because a commit subject can contain anything — including
    /// newlines — and splitting on "\n" would silently shear such a commit into
    /// two bogus rows. Empty on a repo with no commits yet.
    ///
    /// Deliberately git's *default* order rather than `--topo-order`. The graph
    /// does need every commit to precede its parents, but asking git for that
    /// makes it walk the whole repo before emitting a single line — measured at
    /// ~870ms on a 200k-commit history versus ~20ms for the default, and
    /// `--max-count` does not bound it. `CommitOrder.topological` re-establishes
    /// the ordering over just this window for free, so callers that draw the
    /// graph must run the result through it.
    /// `skip` pages further back for the History pane's infinite scroll. It
    /// indexes into git's own default ordering, which is why the pane's window is
    /// always "the newest N by date" even though we then re-sort it — the two
    /// stay in step as long as HEAD hasn't moved, and a moved HEAD reloads from
    /// scratch anyway.
    /// `%D` rides along for the row chips. It costs nothing extra to ask for —
    /// git already has the decoration loaded — and `--decorate=full` is what makes
    /// it parseable (see GitRef.parse). The message stays last: subject and body
    /// are the only fields that can contain anything at all, so keeping them at
    /// the end means a weird one can't shift the fields before it.
    ///
    /// The body rides along for the row's hover tooltip. It costs no extra
    /// process — git is already reading these commits — only bytes, and it's the
    /// only way to show a full message without a `git show` per row. It's split
    /// from the subject on a *group* separator so the record still has exactly
    /// six unit-separated fields: a multi-line body must not be able to change
    /// how many fields a record has.
    static func log(root: String, limit: Int = 300, skip: Int = 0) async -> [GitCommit] {
        let format = "%H\u{1f}%an\u{1f}%at\u{1f}%P\u{1f}%D\u{1f}%s\u{1d}%b\u{1e}"
        var args = ["log", "--max-count=\(limit)", "--decorate=full"]
        if skip > 0 { args.append("--skip=\(skip)") }
        args.append("--format=\(format)")
        let result = await run(args, in: root)
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\u{1e}").compactMap { record in
            let fields = record
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\u{1f}")
            // `>= 6`, not `== 6`: a separator turning up inside a message is
            // vanishingly unlikely but the answer to it is to put the message
            // back together, not to drop the commit out of the history.
            guard fields.count >= 6, !fields[0].isEmpty,
                  let epoch = TimeInterval(fields[2]) else { return nil }
            let message = fields[5...].joined(separator: "\u{1f}")
                .split(separator: "\u{1d}", maxSplits: 1, omittingEmptySubsequences: false)
            return GitCommit(
                sha: fields[0],
                author: fields[1],
                date: Date(timeIntervalSince1970: epoch),
                subject: String(message[0]),
                parents: fields[3].split(separator: " ").map(String.init),
                refs: GitRef.parse(decoration: fields[4]),
                body: message.count > 1
                    ? String(message[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : "")
        }
    }

    /// The commits that exist here but not on the remote — the History pane's blue
    /// dots.
    ///
    /// Two ranges, because the panel has to agree with itself: the header reports
    /// ahead/behind against the *upstream*, so when there is one, the dots have to
    /// be that same set or the header says "↑4" beside five dots. Without an
    /// upstream there's nothing to be ahead *of*, and the useful question becomes
    /// "what have I not pushed anywhere" — `--not --remotes`, which is also what
    /// makes a fresh branch's commits dot correctly before its first push.
    ///
    /// `hasRemotes` is the guard that keeps a purely local repo from dotting every
    /// commit it has: with no remotes, `--not --remotes` excludes nothing and
    /// "unpushed" isn't a thing the repo can mean yet.
    ///
    /// Cost tracks the ahead count, not the repo: both ranges stop at the merge
    /// base, and `--max-count` bounds the pathological case (a long-lived branch,
    /// or a first push of a big import) rather than letting it walk to the root.
    static func unpushedSHAs(
        root: String, upstream: String?, hasRemotes: Bool, limit: Int = 500
    ) async -> Set<String> {
        guard hasRemotes else { return [] }
        var args = ["rev-list", "--max-count=\(limit)"]
        if let upstream {
            args.append("\(upstream)..HEAD")
        } else {
            args += ["HEAD", "--not", "--remotes"]
        }
        let result = await run(args, in: root)
        guard result.ok else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    /// Local and remote branches for the switcher, newest commit first.
    ///
    /// `for-each-ref` reads refs, so this costs ref count rather than repo size —
    /// but it's still loaded lazily (only when the menu opens) rather than folded
    /// into `refresh`, because a monorepo can carry thousands of remote refs and
    /// nothing on screen needs them until you ask.
    static func branches(root: String) async -> [GitBranch] {
        let format = "%(refname)\u{1f}%(objectname)\u{1f}%(upstream:short)\u{1f}%(HEAD)"
        let result = await run(
            ["for-each-ref", "--sort=-committerdate", "--format=\(format)",
             "refs/heads", "refs/remotes"],
            in: root)
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 4 else { return nil }
            let refname = fields[0]
            let upstream = fields[2].isEmpty ? nil : fields[2]
            let isCurrent = fields[3] == "*"
            if refname.hasPrefix("refs/heads/") {
                return GitBranch(
                    name: String(refname.dropFirst("refs/heads/".count)),
                    isRemote: false, sha: fields[1], upstream: upstream, isCurrent: isCurrent)
            }
            if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                // origin/HEAD is a symref to the remote's default branch — it
                // would list a duplicate of origin/main that checks out the same
                // thing. See GitRef.parse, which drops it for the same reason.
                guard !name.hasSuffix("/HEAD") else { return nil }
                return GitBranch(
                    name: name, isRemote: true, sha: fields[1], upstream: nil, isCurrent: false)
            }
            return nil
        }
    }

    // MARK: - Worktrees

    /// Every checkout of this repository, primary first.
    static func worktrees(root: String) async -> [GitWorktree] {
        let result = await run(["worktree", "list", "--porcelain"], in: root)
        guard result.ok else { return [] }
        return GitWorktree.parse(porcelain: result.stdout)
    }

    /// Add a worktree for `branch` at `path`, creating the branch from `base`
    /// when it doesn't exist yet.
    ///
    /// Returns nil on success, or git's own message. Its errors are worth
    /// surfacing verbatim rather than rewriting: "already checked out at …" and
    /// "not a valid object name" both tell the user exactly what to do next, and
    /// a paraphrase would only lose the path.
    static func addWorktree(
        root: String, at path: String, branch: String, createFrom base: String?
    ) async -> String? {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var args = ["worktree", "add"]
        if let base {
            args += ["-b", branch, path, base]
        } else {
            args += [path, branch]
        }
        let result = await run(args, in: root)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git worktree add failed" : message
    }

    /// Remove a worktree. Refuses when it has uncommitted changes — deliberately
    /// not forced: the whole point of a worktree is that work lives in it.
    static func removeWorktree(root: String, at path: String) async -> String? {
        let result = await run(["worktree", "remove", path], in: root)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git worktree remove failed" : message
    }

    /// Whether the repo has any remote configured — decides whether "unpushed"
    /// means anything (see unpushedSHAs).
    static func hasRemotes(root: String) async -> Bool {
        let result = await run(["remote"], in: root)
        return result.ok && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Check out a branch. For a remote one, git's own DWIM creates the local
    /// tracking branch — `git checkout origin/main` would detach HEAD, so the
    /// short name is passed instead and git resolves it.
    ///
    /// Returns git's stderr on failure so the caller can show it verbatim. The
    /// common failure is the useful one: git refuses to check out over changes it
    /// would have to discard, and says which files. That refusal is the safety
    /// here — this never passes `--force`, so an uncommitted worktree cannot be
    /// destroyed by a click in the switcher.
    static func checkout(root: String, branch: GitBranch) async -> String? {
        let name = branch.isRemote ? Self.localName(forRemote: branch.name) : branch.name
        let result = await run(["checkout", name], in: root)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Could not switch to \(name)." : message
    }

    /// "origin/feature/x" → "feature/x". Only the remote name comes off — the
    /// rest is the branch, slashes and all.
    static func localName(forRemote name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// The patch a single commit introduced, ready for DiffParser.
    ///
    /// `--format=` empties the commit header so only the patch reaches the parser.
    /// `-m --first-parent` makes merge commits produce a diff at all (git shows
    /// nothing for a merge by default) — against their first parent, which is the
    /// diff a reader actually means when they click a merge.
    static func commitDiff(root: String, sha: String) async -> String {
        let result = await run(
            ["show", "--format=", "--patch", "-m", "--first-parent", sha], in: root)
        return result.ok ? result.stdout : ""
    }

    /// The files a commit touched, with per-file add/delete counts — the History
    /// pane's changed-files accordion.
    ///
    /// Two `git show` runs rather than one: git prints only a *single* diff
    /// format even when several are asked for (`--name-status` wins over
    /// `--numstat`, verified), so the status letters and the line counts have to
    /// be fetched separately. Both enumerate the same files in the same order, so
    /// they're zipped by index — which also sidesteps reconciling numstat's
    /// `{old => new}` rename spelling against name-status's split old/new paths.
    /// `-m --first-parent` mirrors `commitDiff`: a merge is summarised against its
    /// first parent, the change a reader means when they click it. The two runs
    /// are launched concurrently since neither depends on the other.
    static func commitFiles(root: String, sha: String) async -> [CommitFileChange] {
        // `-M` (find-renames) is explicit rather than relying on the user's
        // `diff.renames` config, so a rename always reads as one R row with the
        // old path remembered — the same in both runs, so they stay index-aligned.
        // `core.quotePath=false` stops git C-quoting non-ASCII paths (its default
        // wraps `café.txt` as `"caf\303\251.txt"`), which would otherwise become
        // the row's path and make every downstream `git show -- <path>` miss.
        async let statusRun = run(
            ["-c", "core.quotePath=false", "show", "--format=", "-m", "--first-parent",
             "-M", "--name-status", sha], in: root)
        async let numstatRun = run(
            ["-c", "core.quotePath=false", "show", "--format=", "-m", "--first-parent",
             "-M", "--numstat", sha], in: root)
        let status = await statusRun
        let numstat = await numstatRun
        guard status.ok else { return [] }

        // Each numstat line: "<adds>\t<dels>\t<path>", counts "-" (→ -1) for a
        // binary file. The path field is left whole (unused; the counts pair is
        // what's zipped in).
        let counts: [(add: Int, del: Int)] = numstat.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                let add = f.count > 0 ? (Int(f[0]) ?? -1) : 0
                let del = f.count > 1 ? (Int(f[1]) ?? -1) : 0
                return (add, del)
            }

        return status.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .compactMap { index, line in
                let fields = line.split(separator: "\t").map(String.init)
                guard let code = fields.first?.first else { return nil }
                // Rename/copy carry a similarity score (R064) and two paths; every
                // other status is one letter and one path.
                let isMove = code == "R" || code == "C"
                let original = isMove && fields.count >= 3 ? fields[1] : nil
                let path = isMove
                    ? (fields.count >= 3 ? fields[2] : fields.last ?? "")
                    : (fields.count >= 2 ? fields[1] : "")
                guard !path.isEmpty else { return nil }
                let (add, del) = index < counts.count ? counts[index] : (0, 0)
                return CommitFileChange(
                    path: path, originalPath: original, statusCode: code,
                    additions: add, deletions: del)
            }
    }

    /// The patch for a single file within a commit, ready for DiffParser — loaded
    /// lazily as the History accordion expands a row. Both the new and (for a
    /// rename) the old path are passed as pathspecs so a rename's diff resolves.
    /// Same `-m --first-parent` merge handling as `commitDiff`.
    static func commitFileDiff(
        root: String, sha: String, path: String, originalPath: String?
    ) async -> String {
        var args = ["-c", "core.quotePath=false", "show", "--format=", "-m",
                    "--first-parent", "-M", sha, "--", path]
        if let originalPath { args.append(originalPath) }
        let result = await run(args, in: root)
        return result.ok ? result.stdout : ""
    }

    /// The image bytes on each side of a change *within a commit*, for the
    /// History accordion — the counterpart to `imageData` (which reads the working
    /// tree). New side is the blob at the commit, old side the blob at its first
    /// parent (`<sha>^`, which for a merge is the first parent — matching the
    /// `-m --first-parent` diff). A side that didn't exist (an add's old, a
    /// delete's new, or a root commit's parent) resolves to an empty blob → nil.
    /// The old side reads the pre-rename path when there is one.
    static func commitImageData(
        root: String, sha: String, file: CommitFileChange
    ) async -> (old: Data?, new: Data?) {
        let oldPath = file.originalPath ?? file.path
        async let oldRun = runData(["show", "\(sha)^:\(oldPath)"], in: root)
        async let newRun = runData(["show", "\(sha):\(file.path)"], in: root)
        let old = await oldRun
        let new = await newRun
        return (old.isEmpty ? nil : old, new.isEmpty ? nil : new)
    }

    static func status(root: String) async -> GitStatus {
        let result = await run(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all"],
            in: root)
        guard result.ok else { return GitStatus() }
        return GitStatusParser.parse(result.stdout)
    }

    /// Which of `paths` (repo-relative) git ignores.
    ///
    /// Asked per **expanded directory** rather than for the repo, because the
    /// obvious alternative — `status --ignored` — walks `node_modules` on every
    /// refresh to answer a question about the twenty rows on screen. This is the
    /// file tree's version of the rule the whole panel is built around: cost
    /// tracks the window, not the repo.
    ///
    /// `check-ignore` exits 1 when *nothing* matched, which is a perfectly
    /// ordinary answer here, so the exit status is deliberately not checked —
    /// only stdout is read. `-z` because a filename may contain a newline.
    static func checkIgnore(root: String, paths: [String]) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = Data((paths.joined(separator: "\0") + "\0").utf8)
        let result = await run(["check-ignore", "-z", "--stdin"], in: root, input: input)
        return Set(result.stdout.split(separator: "\0").map(String.init))
    }

    /// Whether one file differs from HEAD in any way — staged, unstaged or
    /// untracked. One line of porcelain rather than a whole patch, because the
    /// only question being asked is "should this open on its diff?".
    static func workingTreeState(root: String, path: String) async -> WorkingTreeState {
        let result = await run(["status", "--porcelain", "--", path], in: root)
        guard result.ok else { return .unchanged }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .unchanged }
        return line.hasPrefix("??") ? .untracked : .changed
    }

    /// A file git has never seen, shown as additions against nothing — the same
    /// `--no-index` trick `diff(root:change:)` uses for an untracked row.
    static func untrackedDiff(root: String, path: String) async -> String {
        // --no-index exits 1 when the files differ (always, here); the diff is on
        // stdout regardless of exit status.
        await run(["diff", "--no-index", "--", "/dev/null", path], in: root).stdout
    }

    /// What the working tree has done to one path. Three states rather than a
    /// bool because untracked is not a kind of changed: git diffs it differently.
    enum WorkingTreeState {
        case unchanged, changed, untracked
        var hasChanges: Bool { self != .unchanged }
    }

    /// Everything that has happened to one file since the last commit — staged
    /// and unstaged together. This is the question the file tree and a ⌘-clicked
    /// path are asking, where the Changes pane's staged/unstaged split has no
    /// meaning: you pointed at a file, not at one side of its change.
    static func diffAgainstHead(root: String, path: String) async -> String {
        let result = await run(
            ["-c", "core.quotePath=false", "diff", "HEAD", "--", path], in: root)
        return result.ok ? result.stdout : ""
    }

    /// Unified diff text for one file. Untracked files have no index entry, so
    /// their whole content is shown as additions via `--no-index`.
    static func diff(root: String, change: GitFileChange) async -> String {
        if change.untracked {
            return await untrackedDiff(root: root, path: change.path)
        }
        var args = ["diff"]
        if change.staged { args.append("--cached") }
        args += ["--", change.path]
        return await run(args, in: root).stdout
    }

    /// Raw stdout bytes from a git command (for binary blobs like images).
    /// stderr is routed to /dev/null so a large blob on stdout can't wedge.
    /// Returns empty Data on any nonzero exit.
    static func runData(_ args: [String], in directory: String) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = env

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Data())
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : Data())
            }
        }
    }

    /// The image bytes on each side of a change, mirroring what the text diff
    /// would compare: an unstaged row is worktree-vs-index, a staged row is
    /// index-vs-HEAD, an untracked row is just the new worktree file. Any side
    /// that doesn't exist (added/deleted) comes back nil.
    static func imageData(root: String, change: GitFileChange) async -> (old: Data?, new: Data?) {
        let fileURL = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        let diskData = try? Data(contentsOf: fileURL)

        func blob(_ spec: String) async -> Data? {
            let data = await runData(["show", spec], in: root)
            return data.isEmpty ? nil : data
        }

        if change.untracked {
            return (nil, diskData)
        }
        if change.staged {
            let new = change.isDeletion ? nil : await blob(":\(change.path)")
            let old = await blob("HEAD:\(change.path)")
            return (old, new)
        } else {
            let new = change.isDeletion ? nil : diskData
            let old = await blob(":\(change.path)")
            return (old, new)
        }
    }

    // MARK: - Mutations

    static func stage(root: String, change: GitFileChange) async -> CommandResult {
        await run(["add", "--", change.path], in: root)
    }

    static func unstage(root: String, change: GitFileChange) async -> CommandResult {
        // restore --staged is git 2.23+; universal on supported macOS.
        await run(["restore", "--staged", "--", change.path], in: root)
    }

    static func stageAll(root: String) async -> CommandResult {
        await run(["add", "-A"], in: root)
    }

    static func unstageAll(root: String) async -> CommandResult {
        await run(["reset", "-q"], in: root)
    }

    static func commit(root: String, message: String) async -> CommandResult {
        await run(["commit", "-m", message], in: root)
    }

    /// Throw away a file's changes. Untracked → delete the file; staged → reset
    /// both index and worktree to HEAD; unstaged tracked → restore the worktree
    /// from the index. Destructive; callers gate it behind a confirmation.
    static func discard(root: String, change: GitFileChange) async -> CommandResult {
        if change.untracked {
            return await run(["clean", "-f", "--", change.path], in: root)
        }
        if change.staged {
            return await run(
                ["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path],
                in: root)
        }
        return await run(["restore", "--", change.path], in: root)
    }

    /// Append a root-anchored pattern for `path` to the repo's `.gitignore`,
    /// creating the file if needed and keeping one entry per line. IO runs off
    /// the main thread.
    static func addToGitignore(root: String, path: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = URL(fileURLWithPath: root).appendingPathComponent(".gitignore")
                let entry = "/" + path + "\n"
                let existing = (try? Data(contentsOf: url)) ?? Data()
                var data = existing
                // Separate from any prior last line that lacks a trailing newline.
                if let last = existing.last, last != 0x0A { data.append(0x0A) }
                data.append(Data(entry.utf8))
                try? data.write(to: url)
                continuation.resume()
            }
        }
    }

    /// Fetch from the remote, pruning refs deleted upstream so a branch removed
    /// on the server stops lingering in the switcher. Updates the remote-tracking
    /// refs that ahead/behind and the blue dots are measured against, without
    /// touching the work tree — fetch never merges.
    static func fetch(root: String) async -> CommandResult {
        await run(["fetch", "--prune"], in: root)
    }

    /// Push the current branch. On a branch with no upstream yet, set one on
    /// `origin` so the first push just works; otherwise a plain `push`.
    static func push(root: String, setUpstream: Bool) async -> CommandResult {
        var args = ["push"]
        if setUpstream { args += ["--set-upstream", "origin", "HEAD"] }
        return await run(args, in: root)
    }

    /// The staged changes as a stat summary + full patch, for feeding a model
    /// that drafts a commit message. Returns the two parts separately so the
    /// drafter can keep the (cheap, whole-picture) stat while budgeting the
    /// patch per file. Nil when nothing is staged.
    static func stagedDiff(root: String) async -> (stat: String, patch: String)? {
        let stat = await run(["diff", "--cached", "--stat"], in: root).stdout
        let patch = await run(["diff", "--cached"], in: root).stdout
        guard !patch.isEmpty else { return nil }
        return (stat, patch)
    }
}
