import Foundation
import os

/// Stateless async wrapper around the `git` CLI. Every call runs the process on
/// a background queue and resumes on the caller's async context, so nothing here
/// ever blocks the main thread. Callers (the @MainActor models) marshal results
/// back themselves — same discipline as the libghostty callbacks.
enum GitService {
    /// What the two pipe readers in `run` fill in. A named type rather than a
    /// tuple so the lock's state is unambiguously Sendable.
    private struct Drained: Sendable {
        var out = Data()
        var err = Data()
    }

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
    /// What every git we run is told, whatever the user's config says.
    ///
    /// `core.fsmonitor=false`: with fsmonitor on in the user's config, each
    /// repo git touches starts a `fsmonitor--daemon` that outlives us for good,
    /// and we touch a lot of repos (every worktree, for the header's counts).
    /// Seen: 25 of them left running for days. They don't even buy us speed:
    /// the daemon answers relative to a token stored in the index, our reads
    /// never write the index (below), and the git that does write it is
    /// usually the shell's, a different binary with its own daemon. So for us
    /// it's a process left behind per repo for a scan we run anyway.
    private static func gitArguments(_ args: [String]) -> [String] {
        ["git", "-c", "core.fsmonitor=false"] + args
    }

    /// Never let git block on a credential/terminal prompt, and don't let it
    /// take the index.lock just to read status.
    private static let gitEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath(env["PATH"])
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }()

    /// The folders command-line tools are installed in, beyond the system's.
    ///
    /// An app opened from the Dock gets launchd's PATH, `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// and none of these. git itself is in `/usr/bin`, but what it runs on the
    /// user's behalf often isn't: `git-lfs`, which a repository with large files
    /// can't check anything out without (`filter.lfs.required`), a credential
    /// helper, a hook's tools. Without them a Fork in such a repository failed
    /// with "git-lfs: command not found" while the same command worked in every
    /// shell.
    static let installDirectories: [String] = {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.nix-profile/bin",
                "/etc/profiles/per-user/\(NSUserName())/bin", "/run/current-system/sw/bin",
                "\(home)/.local/bin", "/opt/local/bin"]
    }()

    /// `path` with the install folders it lacks added **after** its own, so a
    /// `git` already on it stays the one that runs and only what's missing is
    /// found further along. (A Nix git on the work laptop is a different binary
    /// with its own speed; swapping it in by accident is not this change.)
    static func toolPath(_ path: String?, adding extra: [String] = installDirectories) -> String {
        var entries = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if entries.isEmpty { entries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for directory in extra where !entries.contains(directory) { entries.append(directory) }
        return entries.joined(separator: ":")
    }

    /// Every git we've started and not yet seen exit, by pid (which is also its
    /// process group), so quitting can stop them (`terminateAll`). A `fetch`
    /// stuck on a dead network otherwise outlives the app by as long as the
    /// network takes to say so, which can be never.
    private static let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Stop every git still running, and what it started. Called as the app
    /// quits.
    static func terminateAll() {
        for group in live.withLock({ $0 }) { kill(-group, SIGTERM) }
    }

    /// How long a command that talks to a remote may take before it's stopped.
    /// Generous, because a big fetch on a slow link is real work; the point is
    /// only that a hung one ends.
    static let networkTimeout: TimeInterval = 300

    /// Start git in a process group of its own, so stopping it stops
    /// everything it started.
    ///
    /// Why not `Process`: it leaves the child in our group, and signalling git
    /// alone was measured not to be enough. A fetch's ssh survived it,
    /// reparented to launchd, and held our pipes open, so a call that was
    /// meant to end at its time limit waited for the ssh instead. Hunting the
    /// children down by parent pid first still lost a race to one started a
    /// moment later. A group catches every process git starts, then or later,
    /// and `kill(-group)` can't reach the app.
    ///
    /// The child gets exactly stdin, stdout and stderr (`CLOEXEC_DEFAULT`),
    /// none of the app's other descriptors, and default signal handling.
    /// Returns nil when it couldn't start.
    private static func spawn(
        _ argv: [String], environment: [String: String], in directory: String,
        stdin: Int32?, stdout: Int32, stderr: Int32?
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        if let stderr {
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0) // a new group, led by git
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)

        let cArgv = (["env"] + argv).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, cArgv, envp) == 0 else {
            return nil
        }
        live.withLock { _ = $0.insert(pid) }
        return pid
    }

    /// Wait for git to exit, stopping its whole group if it outlives
    /// `timeout`: SIGTERM, then SIGKILL two seconds on. Returns what
    /// `Process.terminationStatus` would: the exit code, or the signal.
    ///
    /// The limit is kept by the thread that is here to wait anyway, rather
    /// than a timer on a background queue, which is the system's to defer.
    private static func wait(for pid: pid_t, timeout: TimeInterval?) -> Int32 {
        let status = OSAllocatedUnfairLock(initialState: Int32(0))
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            status.withLock { $0 = raw }
            exited.signal()
        }
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                kill(-pid, SIGTERM)
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(-pid, SIGKILL)
                    exited.wait()
                }
            }
        } else {
            exited.wait()
        }
        // Whatever git left in its group (a transport on its way out) goes
        // with it: nothing in there is ours to keep, and it holds our pipes.
        kill(-pid, SIGTERM)
        live.withLock { _ = $0.remove(pid) }
        let raw = status.withLock { $0 }
        return (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : raw & 0x7F
    }

    /// A pipe whose ends don't leak into anything else the app starts.
    private static func makePipe() -> (read: FileHandle, write: FileHandle)? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    static func run(_ args: [String], in directory: String, input: Data? = nil,
                    timeout: TimeInterval? = nil) async -> CommandResult {
        await execute(gitArguments(args), environment: gitEnvironment, in: directory,
                      input: input, timeout: timeout)
    }

    /// Another command-line tool, run the way git is: its own process group,
    /// stopped at `timeout` and on quit, never waiting on a prompt. `argv[0]`
    /// is a full path, or found on `environment`'s PATH.
    static func runTool(_ argv: [String], environment: [String: String], in directory: String,
                        timeout: TimeInterval) async -> CommandResult {
        await execute(argv, environment: environment, in: directory, input: nil, timeout: timeout)
    }

    private static func execute(_ argv: [String], environment: [String: String], in directory: String,
                                input: Data?, timeout: TimeInterval?) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let out = makePipe(), let err = makePipe() else {
                    continuation.resume(returning: CommandResult(
                        status: -1, stdout: "", stderr: "couldn't create a pipe"))
                    return
                }
                let inPipe = input == nil ? nil : makePipe()
                guard let pid = spawn(argv, environment: environment, in: directory,
                                      stdin: inPipe?.read.fileDescriptor,
                                      stdout: out.write.fileDescriptor,
                                      stderr: err.write.fileDescriptor)
                else {
                    continuation.resume(returning: CommandResult(
                        status: -1, stdout: "", stderr: "couldn't start \(argv.first ?? "it")"))
                    return
                }
                // The child has its copies. Ours must go, or the readers below
                // would wait on a write end we hold ourselves.
                try? out.write.close()
                try? err.write.close()
                try? inPipe?.read.close()

                // Drain both pipes off separate threads before waiting, so a
                // full pipe buffer never wedges the child.
                //
                // Collected under a lock rather than into two captured `var`s.
                // The group below already orders both writes before the read
                // after it, so the old version produced the right answer every
                // time — but two concurrent blocks mutating captured storage is
                // a data race by the language's rules whatever the runtime
                // ordering, and this runs on every git call the app makes.
                let collected = OSAllocatedUnfairLock(initialState: Drained())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = out.read.readDataToEndOfFile()
                    collected.withLock { $0.out = data }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = err.read.readDataToEndOfFile()
                    collected.withLock { $0.err = data }
                    group.leave()
                }
                if let inPipe, let input {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The close is what tells git the list is finished; without
                        // it `--stdin` waits forever. try? because a child that
                        // exited early (a bad argument) leaves us writing to a
                        // broken pipe, which is a failed command, not a crash.
                        try? inPipe.write.write(contentsOf: input)
                        try? inPipe.write.close()
                        group.leave()
                    }
                }
                let status = wait(for: pid, timeout: timeout)
                group.wait()

                let drained = collected.withLock { $0 }
                continuation.resume(returning: CommandResult(
                    status: status,
                    stdout: String(decoding: drained.out, as: UTF8.self),
                    stderr: String(decoding: drained.err, as: UTF8.self)))
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
        await branches(root: root, refs: ["refs/heads", "refs/remotes"])
    }

    /// Just the local branches, for the callers that only ever wanted those.
    ///
    /// The namespace is narrowed in *git* rather than filtered afterwards, and
    /// on a monorepo that is the whole cost of the call. `--sort=-committerdate`
    /// has to load the commit each ref points at to read its date, so asking for
    /// `refs/remotes` and then dropping it walks tens of thousands of objects to
    /// produce a list of nine. Local branches stay few even in repositories
    /// where remote refs do not.
    static func localBranches(root: String) async -> [GitBranch] {
        await branches(root: root, refs: ["refs/heads"])
    }

    /// Just the remote-tracking branches. The expensive half, and the reason
    /// everything that can be answered without it is: this is the call that
    /// costs 140ms on a repository with 4000 remote refs, so it is loaded after
    /// whatever needed it is already on screen, never before.
    static func remoteBranches(root: String) async -> [GitBranch] {
        await branches(root: root, refs: ["refs/remotes"])
    }

    private static func branches(root: String, refs: [String]) async -> [GitBranch] {
        // `worktreepath` and the date are read off the ref and the commit the
        // sort already loads: nothing extra to walk.
        let format = "%(refname)\u{1f}%(objectname)\u{1f}%(upstream:short)\u{1f}%(HEAD)\u{1f}%(worktreepath)\u{1f}%(committerdate:unix)"
        let result = await run(
            ["for-each-ref", "--sort=-committerdate", "--format=\(format)"] + refs,
            in: root)
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 6 else { return nil }
            let refname = fields[0]
            let upstream = fields[2].isEmpty ? nil : fields[2]
            let isCurrent = fields[3] == "*"
            let date = TimeInterval(fields[5]).map { Date(timeIntervalSince1970: $0) }
            if refname.hasPrefix("refs/heads/") {
                return GitBranch(
                    name: String(refname.dropFirst("refs/heads/".count)),
                    isRemote: false, sha: fields[1], upstream: upstream, isCurrent: isCurrent,
                    worktreePath: fields[4].isEmpty ? nil : fields[4], date: date)
            }
            if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                // origin/HEAD is a symref to the remote's default branch — it
                // would list a duplicate of origin/main that checks out the same
                // thing. See GitRef.parse, which drops it for the same reason.
                guard !name.hasSuffix("/HEAD") else { return nil }
                return GitBranch(
                    name: name, isRemote: true, sha: fields[1], upstream: nil, isCurrent: false,
                    date: date)
            }
            return nil
        }
    }

    /// The branch a new branch should fork from when nothing else is said —
    /// trunk, not wherever you happen to be standing.
    ///
    /// `origin/HEAD` is the honest answer where it exists: it's a symref to the
    /// remote's default branch, so it survives a repo whose trunk is `master`,
    /// `develop`, or something else entirely. It's also *local* state, written at
    /// clone time — a repo cloned before the default was renamed, or one created
    /// by `git init` and pushed, may not have it at all. Hence the fallbacks, in
    /// the order a person would guess: the conventional names, then whatever is
    /// checked out, and finally nothing (a repo with no commits, where there is no
    /// base to name and git infers an orphan branch instead).
    static func defaultBranch(root: String) async -> String? {
        let symref = await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root)
        if symref.ok {
            // "origin/main" -> "main". Split once from the left: a remote name has
            // no slash, but a branch name may (`origin/release/2026`).
            let name = symref.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") {
                let branch = String(name[name.index(after: slash)...])
                if !branch.isEmpty { return branch }
            }
        }
        let locals = await localBranches(root: root)
        for candidate in ["main", "master"] where locals.contains(where: { $0.name == candidate }) {
            return candidate
        }
        return locals.first(where: \.isCurrent)?.name ?? locals.first?.name
    }

    /// The ref a new branch should *fork from* — trunk as origin last reported
    /// it, rather than trunk as of whenever you last pulled.
    ///
    /// `defaultBranch` names the local branch, and that is the wrong thing to
    /// hand `worktree add`. A fetch only ever moves `refs/remotes/*`: it does
    /// not fast-forward a local `main`, and nothing else here does either, so a
    /// repository you have been working in for a week forks its "new" branch
    /// from a week-old commit. The remote-tracking ref is the same trunk,
    /// current as of the last fetch, which is why `newSessionOnBranch` runs one
    /// while the dialog is open.
    ///
    /// Falls back to the local branch where there is no remote copy to prefer:
    /// a repository with no remote, or a trunk that has never been pushed.
    ///
    /// **The remote is trunk's own upstream, not `origin`.** Asking for
    /// `origin/<trunk>` by name is right for almost every repository and wrong
    /// for exactly the ones that most need this: a fork checkout, where trunk
    /// tracks `upstream/main` and `refs/remotes/origin/main` is either absent or
    /// is *your* fork's stale copy. The first case silently returns the local
    /// branch, so the fetch is paid for and the fork point is stale anyway; the
    /// second is worse, because it looks like it worked. Trunk's upstream is
    /// what "the remote copy of trunk" means, and git already tracks it.
    static func defaultBase(root: String) async -> String? {
        guard let local = await defaultBranch(root: root) else { return nil }
        let upstream = await run(
            ["rev-parse", "--abbrev-ref", "--verify", "--quiet", local + "@{upstream}"], in: root)
        let tracked = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if upstream.ok, !tracked.isEmpty { return tracked }
        // No upstream configured, which a trunk you have never pushed will not
        // have. `origin/<trunk>` is still the good guess: the ref can exist
        // without the local branch tracking it (a fresh clone that has never
        // pulled, a branch recreated locally), and where it does it is the same
        // trunk, fresher.
        let guess = "origin/" + local
        let exists = await run(
            ["rev-parse", "--verify", "--quiet", "refs/remotes/" + guess], in: root)
        return exists.ok ? guess : local
    }

    // MARK: - Worktrees

    /// Where this checkout keeps its git state, when that is somewhere other than
    /// `<root>/.git` — which is exactly the linked-worktree case.
    ///
    /// A linked worktree's `.git` is a *file* pointing at
    /// `<primary>/.git/worktrees/<name>`, and that directory is where its HEAD,
    /// its index and its reflog live. So nothing under the worktree's own root
    /// moves when you stage, commit, or check out in it — which makes a watcher
    /// rooted at the work tree blind to every git operation performed there, and
    /// leaves the panel showing files that were committed minutes ago. The
    /// primary checkout answers with `<root>/.git`, already inside the work tree,
    /// so it gets nothing extra.
    ///
    /// Deliberately *not* the common dir (`<primary>/.git`): our own gitdir is
    /// what carries this checkout's HEAD and index, while the common dir also
    /// carries `objects/` and every *other* worktree's state — watching it would
    /// make one agent's fetch scan the work tree of every open session.
    static func externalGitDir(root: String) async -> String? {
        let result = await run(["rev-parse", "--absolute-git-dir"], in: root)
        guard result.ok else { return nil }
        let dir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, !isPath(dir, within: root) else { return nil }
        return dir
    }

    /// Whether `path` is `root` or sits under it.
    ///
    /// Two ways to get this wrong, and both answer "no" to a path that is
    /// plainly inside: `hasPrefix` on its own calls `/a/repo-old` a child of
    /// `/a/repo`, so the comparison is on whole components; and a repo under
    /// `/tmp` or `/var` is reached by a symlink, so one side can say `/var/…`
    /// while git answers with `/private/var/…`. Both sides are resolved — the
    /// same trap the worktree-ownership check has to avoid.
    private static func isPath(_ path: String, within root: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let root = resolved(root)
        let path = resolved(path)
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// How many commits `to` has that `from` doesn't. 0 when either is
    /// unknown.
    static func commitsAhead(from: String, to: String, root: String) async -> Int {
        let result = await run(["rev-list", "--count", "\(from)..\(to)"], in: root)
        guard result.ok else { return 0 }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Every checkout of this repository, primary first.
    static func worktrees(root: String) async -> [GitWorktree] {
        let result = await run(["worktree", "list", "--porcelain"], in: root)
        guard result.ok else { return [] }
        return GitWorktree.parse(porcelain: result.stdout)
    }

    /// What a new worktree checks out.
    enum WorktreeSource {
        /// A branch that already exists: `git worktree add <path> <branch>`.
        case existingBranch
        /// A new branch forked from `base`, or — when `base` is nil, which is a
        /// repository with no commits yet — from nothing. Git calls that an
        /// orphan and infers it happily; what it *won't* accept is being handed
        /// `HEAD` as a base when HEAD doesn't resolve, which is what a freshly
        /// `git init`ed repo does and where this used to fail outright.
        case newBranch(from: String?)
    }

    /// Add a worktree for `branch` at `path`.
    ///
    /// Returns nil on success, or git's own message. Its errors are worth
    /// surfacing verbatim rather than rewriting: "already checked out at …" and
    /// "not a valid object name" both tell the user exactly what to do next, and
    /// a paraphrase would only lose the path.
    static func addWorktree(
        root: String, at path: String, branch: String, source: WorktreeSource
    ) async -> String? {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Drop records for worktrees whose directories are gone — deleted by
        // hand, or on a volume that isn't mounted. Git keeps the registration
        // either way, and the next `add` for that branch fails on a directory
        // nobody can see.
        _ = await run(["worktree", "prune"], in: root)

        var args = ["worktree", "add"]
        switch source {
        case .existingBranch:
            args += [path, branch]
        case .newBranch(let base):
            args += ["-b", branch]
            // Forking from `origin/main` would otherwise make `origin/main` the
            // new branch's upstream, and `push.default=simple` refuses to push a
            // branch whose upstream is named something else — so the first push
            // from the session would fail on a repository that had done nothing
            // wrong. A branch forked from a *local* one gets no upstream anyway,
            // so this only ever removes surprise. `push(setUpstream:)` sets the
            // right one the first time it is asked.
            if base != nil { args.append("--no-track") }
            args.append(path)
            if let base { args.append(base) }
        }
        let result = await run(args, in: root)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git worktree add failed" : message
    }

    /// Whether the repository has any commit yet. A fresh `git init` has none,
    /// and HEAD points at a branch that doesn't exist — which is legal, and the
    /// state most things quietly assume away.
    static func hasCommits(root: String) async -> Bool {
        await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok
    }

    /// Remove a worktree. Refuses when it has uncommitted changes — deliberately
    /// not forced: the whole point of a worktree is that work lives in it.
    /// (The app's own removal goes through `WorktreeCleanup.remove`, which
    /// checks more than git does and keeps the folder in the Trash.)
    static func removeWorktree(root: String, at path: String) async -> String? {
        let result = await run(["worktree", "remove", path], in: root)
        guard !result.ok else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git worktree remove failed" : message
    }

    /// Which remotes carry a branch of this name.
    ///
    /// Asked one O(1) ref lookup per remote rather than by listing
    /// `refs/remotes` and searching it. The listing is the expensive thing on a
    /// repository with many remote refs (140ms at 4000 of them), and a
    /// repository has one or two remotes, so this costs two `rev-parse`s where
    /// the obvious version costs a walk of every ref in the repository.
    static func remotesWithBranch(root: String, branch: String) async -> [String] {
        let listed = await run(["remote"], in: root)
        guard listed.ok else { return [] }
        var found: [String] = []
        for line in listed.stdout.split(separator: "\n") {
            let remote = line.trimmingCharacters(in: .whitespaces)
            guard !remote.isEmpty else { continue }
            let ref = "refs/remotes/\(remote)/\(branch)"
            if await run(["rev-parse", "--verify", "--quiet", ref], in: root).ok {
                found.append(remote)
            }
        }
        return found
    }

    /// The remote git itself would pick when a branch name is on more than one.
    ///
    /// `checkout.defaultRemote` is git's own answer to that ambiguity, and it is
    /// set by exactly the people who hit it: anyone working against a fork, with
    /// `origin` and `upstream` carrying the same branch names. Without it
    /// `worktree add <path> <name>` refuses (`invalid reference`); with it, git
    /// resolves the name and sets up tracking as if there had never been a
    /// question. So the ambiguity is only real when git has no answer, and
    /// asking is one `config` read.
    static func defaultRemote(root: String) async -> String? {
        let result = await run(["config", "--get", "checkout.defaultRemote"], in: root)
        guard result.ok else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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
        // In a sentence (GitMessage): the files a switch would overwrite, or
        // the folder a branch is busy in when an agent took it since the list
        // opened (the list itself routes those to Show).
        return GitMessage.readable(result.stderr, while: .switching(to: name))
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

    /// `status` for work nobody is looking at yet: the other worktrees' change
    /// counts behind the repo header's hint. Queued app-wide, one at a time,
    /// so however many of these pile up (a read per session flicked past, the
    /// header's timer) they cost one core at most, and the scan for the repo
    /// on screen, which isn't queued, never waits behind them.
    /// `light`: the counts only, as the other-worktree scans want them:
    /// `normal` untracked files (a new folder is one change, not a walk of
    /// every file in it, which on a fresh `node_modules` is the whole cost)
    /// and no rename detection.
    static func backgroundStatus(root: String, light: Bool = false) async -> GitStatus {
        await backgroundScans.run {
            guard light else { return await status(root: root) }
            let result = await run(
                ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--no-renames"],
                in: root)
            guard result.ok else { return GitStatus() }
            return GitStatusParser.parse(result.stdout)
        }
    }

    private static let backgroundScans = SerialGate()

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
                guard let out = makePipe(),
                      let pid = spawn(gitArguments(args), environment: gitEnvironment,
                                      in: directory, stdin: nil,
                                      stdout: out.write.fileDescriptor, stderr: nil)
                else {
                    continuation.resume(returning: Data())
                    return
                }
                try? out.write.close()
                let data = out.read.readDataToEndOfFile()
                let status = wait(for: pid, timeout: nil)
                continuation.resume(returning: status == 0 ? data : Data())
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

    static func stage(root: String, changes: [GitFileChange]) async -> CommandResult {
        await runBatched(["add", "--"], paths: changes.map(\.path), in: root)
    }

    static func unstage(root: String, changes: [GitFileChange]) async -> CommandResult {
        // restore --staged is git 2.23+; universal on supported macOS.
        await runBatched(["restore", "--staged", "--"], paths: changes.map(\.path), in: root)
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

    /// Throw away changes. Untracked → delete the file; staged → reset both index
    /// and worktree to HEAD; unstaged tracked → restore the worktree from the
    /// index. Destructive; callers gate it behind a confirmation.
    ///
    /// Runs at most one `git` per kind rather than one per file, because the
    /// panel's cost rule applies hardest here: each mutation is followed by a
    /// `git status`, which is a full worktree walk, so discarding a forty-file
    /// selection a file at a time is forty of them next to a terminal that has to
    /// stay smooth.
    static func discard(root: String, changes: [GitFileChange]) async -> CommandResult {
        var last = CommandResult(status: 0, stdout: "", stderr: "")
        for command in discardCommands(for: changes) {
            let result = await runBatched(command.arguments, paths: command.paths, in: root)
            // Report the first failure, but keep going: the groups are
            // independent, and stopping would leave a partial discard that the
            // list can't explain (half the rows you confirmed are still there).
            if !result.ok, last.ok { last = result }
        }
        return last
    }

    /// One `git` invocation per kind of discard, in the order they must run.
    ///
    /// Pure, and pinned by tests, because the three kinds are not
    /// interchangeable and nothing complains when they're mixed up: `clean` on a
    /// tracked path is a no-op that leaves the edit in place, and `restore` on an
    /// untracked file fails with "pathspec did not match" while the row it came
    /// from disappears from the list on the next status either way. Both look
    /// exactly like a discard that worked.
    ///
    /// Staged goes first so a file selected on *both* sides ends at HEAD rather
    /// than at whatever the index held.
    static func discardCommands(for changes: [GitFileChange]) -> [(arguments: [String], paths: [String])] {
        let untracked = changes.filter(\.untracked).map(\.path)
        let staged = changes.filter { $0.staged && !$0.untracked }.map(\.path)
        let unstaged = changes.filter { !$0.staged && !$0.untracked }.map(\.path)

        var commands: [(arguments: [String], paths: [String])] = []
        if !staged.isEmpty {
            commands.append((["restore", "--staged", "--worktree", "--source=HEAD", "--"], staged))
        }
        if !unstaged.isEmpty { commands.append((["restore", "--"], unstaged)) }
        if !untracked.isEmpty { commands.append((["clean", "-f", "--"], untracked)) }
        return commands
    }

    /// Run `git <arguments> <paths…>`, split into as many invocations as the
    /// argument list needs.
    ///
    /// A selection is bounded by what a person highlights, but Select All on a
    /// repo mid-rebase (or with an unignored build directory) is thousands of
    /// rows, and an argv over the kernel's `ARG_MAX` doesn't come back as a git
    /// error, it comes back as a spawn failure with nothing done. Chunking by
    /// bytes rather than by count is the honest bound: paths here are as long as
    /// the repo makes them.
    private static func runBatched(
        _ arguments: [String], paths: [String], in root: String
    ) async -> CommandResult {
        var last = CommandResult(status: 0, stdout: "", stderr: "")
        for chunk in chunked(paths) {
            let result = await run(arguments + chunk, in: root)
            if !result.ok, last.ok { last = result }
        }
        return last
    }

    /// Split `paths` into groups whose combined length stays well under the
    /// system's argument limit (256KB on macOS, and the environment shares it).
    static func chunked(_ paths: [String], budget: Int = 96 * 1024) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var size = 0
        for path in paths {
            let cost = path.utf8.count + 1
            // A single path over budget still has to go somewhere: on its own,
            // where it's the kernel's problem rather than a silently dropped row.
            if !current.isEmpty, size + cost > budget {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(path)
            size += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Append root-anchored patterns for `paths` to the repo's `.gitignore`,
    /// creating the file if needed and keeping one entry per line. IO runs off
    /// the main thread, and the whole selection is one read-modify-write: a file
    /// per entry would race itself and lose all but the last.
    static func addToGitignore(root: String, paths: [String]) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = URL(fileURLWithPath: root).appendingPathComponent(".gitignore")
                let existing = (try? Data(contentsOf: url)) ?? Data()
                var data = existing
                // Separate from any prior last line that lacks a trailing newline.
                if let last = existing.last, last != 0x0A { data.append(0x0A) }
                for path in paths { data.append(Data(("/" + path + "\n").utf8)) }
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
        await run(["fetch", "--prune"], in: root, timeout: networkTimeout)
    }

    /// Pull the current branch, fast-forward only. A panel with no conflict UI
    /// has no business starting a merge or a rebase it can't finish, so a
    /// diverged branch gets git's refusal in the error banner and the terminal
    /// is right there to resolve it in. `git pull` fetches first, so this is
    /// "catch up with the remote" in one step, not a merge of a stale ref.
    static func pull(root: String) async -> CommandResult {
        await run(["pull", "--ff-only"], in: root, timeout: networkTimeout)
    }

    /// Push the current branch. On a branch with no upstream yet, set one on
    /// `origin` so the first push just works; otherwise a plain `push`.
    static func push(root: String, setUpstream: Bool) async -> CommandResult {
        var args = ["push"]
        if setUpstream { args += ["--set-upstream", "origin", "HEAD"] }
        return await run(args, in: root, timeout: networkTimeout)
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

/// Runs async work one piece at a time, in arrival order. A lock can't do this
/// (the work suspends), and a serial queue can't await.
actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        let result = await work()
        // Hand the turn straight to the next in line, so nobody can slip in
        // between and two run at once.
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        return result
    }
}
