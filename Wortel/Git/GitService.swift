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
    static func run(_ args: [String], in directory: String) async -> CommandResult {
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

    static func status(root: String) async -> GitStatus {
        let result = await run(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all"],
            in: root)
        guard result.ok else { return GitStatus() }
        return GitStatusParser.parse(result.stdout)
    }

    /// Unified diff text for one file. Untracked files have no index entry, so
    /// their whole content is shown as additions via `--no-index`.
    static func diff(root: String, change: GitFileChange) async -> String {
        if change.untracked {
            // --no-index exits 1 when the files differ (always, here); the diff
            // is on stdout regardless of exit status.
            let result = await run(
                ["diff", "--no-index", "--", "/dev/null", change.path], in: root)
            return result.stdout
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
