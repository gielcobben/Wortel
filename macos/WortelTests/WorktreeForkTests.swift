import XCTest

/// Fork Session's git half. The promise is exact: the new worktree holds what
/// the source held at the press, staged as staged and unstaged as unstaged,
/// byte for byte, and the source isn't touched while it's read. git is the
/// oracle on both sides: the same diffs and the same untracked files, read
/// the same way.
final class WorktreeForkTests: XCTestCase {
    private var repo: URL!
    private var forks: [URL] = []
    /// Never the real `~/.wortel/staging`: a running Wortel may be using it.
    private var staging: URL!

    override func setUp() {
        repo = GitFixture.newRepo("fork")
        staging = repo.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString)")
    }

    override func tearDown() {
        GitFixture.destroy(repo)
        forks.forEach(GitFixture.destroy)
        GitFixture.destroy(staging)
    }

    private func write(_ path: String, _ data: Data, in base: URL? = nil) {
        let url = (base ?? repo).appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func write(_ path: String, _ text: String) { write(path, Data(text.utf8)) }

    private func sh(_ command: String, in dir: URL? = nil) { GitFixture.sh(command, in: dir ?? repo) }

    /// A repository with every kind of uncommitted change at once.
    private func makeMessySource() {
        write("README.md", "one\n")
        write("script.sh", "echo hi\n")
        write("bin.dat", Data((0..<512).map { UInt8($0 % 256) }))
        write("gone.txt", "bye\n")
        write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A])) // "café" in Latin-1
        write(".gitignore", ".env\n")
        sh("git add -A && git commit -q -m base")
        // staged only: a new file
        write("staged.txt", "staged\n")
        sh("git add staged.txt")
        // staged, then edited again unstaged
        write("README.md", "one\ntwo\n")
        sh("git add README.md")
        write("README.md", "one\ntwo\nthree\n")
        // unstaged only, plus a mode change
        write("script.sh", "echo bye\n")
        sh("chmod +x script.sh")
        // binary modified, deletion, non-UTF-8 content
        write("bin.dat", Data((0..<600).map { UInt8(($0 * 7) % 256) }))
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        write("latin1.txt", Data([0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A])) // "naïve"
        // untracked: binary, unicode name with a space, a symlink; ignored .env
        write("blob.bin", Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
        write("über file.txt", "unicode\n")
        try? FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link").path,
                                                    withDestinationPath: "README.md")
        write(".env", "SECRET=1\n")
    }

    private func newWorktree(at head: String?) -> URL {
        let target = repo.deletingLastPathComponent().appendingPathComponent("fork-\(UUID().uuidString)")
        forks.append(target)
        sh("git worktree add -q -b fork-\(UUID().uuidString.prefix(8)) \(GitFixture.shellQuoted(target.path)) \(head ?? "")")
        return target
    }

    private func state(of dir: URL) async -> (staged: Data, unstaged: Data, untracked: [String]) {
        let staged = await GitService.runData(["diff", "--cached", "--binary", "--no-ext-diff"], in: dir.path)
        let unstaged = await GitService.runData(["diff", "--binary", "--no-ext-diff"], in: dir.path)
        let untracked = await GitService.runData(["ls-files", "-z", "--others", "--exclude-standard"], in: dir.path)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
        return (staged, unstaged, untracked)
    }

    func testForkCarriesEverythingExactly() async throws {
        makeMessySource()
        let snapshot = try await WorktreeFork.snapshot(of: repo.path, named: "src", stagingRoot: staging).get()
        let target = newWorktree(at: snapshot.head)
        let warnings = try await WorktreeFork.apply(snapshot, to: target.path).get()
        XCTAssertEqual(warnings, [])

        let source = await state(of: repo)
        let fork = await state(of: target)
        XCTAssertFalse(source.staged.isEmpty)
        XCTAssertFalse(source.unstaged.isEmpty)
        XCTAssertEqual(fork.staged, source.staged, "staged changes differ")
        XCTAssertEqual(fork.unstaged, source.unstaged, "unstaged changes differ")
        XCTAssertEqual(fork.untracked, source.untracked)
        for file in ["blob.bin", "über file.txt"] {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(file)),
                           try Data(contentsOf: repo.appendingPathComponent(file)), file)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: target.appendingPathComponent("link").path), "README.md")
        // Ignored files are .worktreeinclude's business, not the fork's.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".env").path))
        // The staging folder is gone once applied.
        if let staging = snapshot.staging {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    /// Reading the source changes nothing in it: not its status, not its
    /// index (which `git stash` would rewrite under a running agent).
    func testSnapshotLeavesTheSourceAlone() async throws {
        makeMessySource()
        let index = repo.appendingPathComponent(".git/index")
        let before = await GitService.runData(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repo.path)
        let stamp = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let snapshot = try await WorktreeFork.snapshot(of: repo.path, named: "src", stagingRoot: staging).get()
        defer { snapshot.discard() }
        let after = await GitService.runData(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repo.path)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date, stamp)
    }

    func testMergeInProgressIsRefused() async {
        write("f.txt", "base\n")
        sh("git add -A && git commit -q -m base && git checkout -q -b other")
        write("f.txt", "other\n")
        sh("git commit -q -am other && git checkout -q main")
        write("f.txt", "main\n")
        sh("git commit -q -am main && git merge -q other")
        guard case .failure(let refusal) = await WorktreeFork.snapshot(of: repo.path, named: "src", stagingRoot: staging) else {
            return XCTFail("a conflicted checkout must not be forked")
        }
        XCTAssertTrue(refusal.message.contains("middle of a merge"))
    }

    /// No commit yet: nothing to make the worktree at, so it's an orphan and
    /// everything arrives as new.
    func testUnbornHeadForks() async throws {
        write("new.txt", "hello\n")
        sh("git add new.txt")
        let snapshot = try await WorktreeFork.snapshot(of: repo.path, named: "src", stagingRoot: staging).get()
        XCTAssertNil(snapshot.head)
        let target = repo.deletingLastPathComponent().appendingPathComponent("fork-\(UUID().uuidString)")
        forks.append(target)
        let error = await GitService.addWorktree(root: repo.path, at: target.path, branch: "worktree/orphan",
                                                 source: .newBranch(from: nil))
        XCTAssertNil(error)
        _ = try await WorktreeFork.apply(snapshot, to: target.path).get()
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("new.txt"), encoding: .utf8), "hello\n")
    }

    /// When the patch won't apply, the files are copied and the fork says so.
    func testPatchThatWontApplyFallsBackToCopying() async throws {
        write("a.txt", "one\n")
        sh("git add -A && git commit -q -m base")
        write("a.txt", "one\ntwo\n")
        let real = try await WorktreeFork.snapshot(of: repo.path, named: "src", stagingRoot: staging).get()
        let broken = WorktreeFork.Snapshot(
            sourceRoot: real.sourceRoot, head: real.head, staged: Data(),
            unstaged: Data("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -9 +9 @@\n-nope\n+nope\n".utf8),
            staging: nil, untracked: [], changed: real.changed, warnings: [])
        let target = newWorktree(at: real.head)
        let warnings = try await WorktreeFork.apply(broken, to: target.path).get()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "one\ntwo\n")
    }

    // MARK: - Pure parts

    func testStatusParse() {
        let raw = "# branch.oid abc\0"
            + "1 M. N... 100644 100644 100644 aaa bbb staged only.txt\0"
            + "1 .M N... 100644 100644 100644 aaa aaa work.txt\0"
            + "1 MM N... 100644 100644 100644 aaa bbb both.txt\0"
            + "? new file.txt\0"
            + "! ignored.log\0"
        let status = WorktreeFork.parseStatus(Data(raw.utf8))
        XCTAssertFalse(status.unmerged)
        XCTAssertEqual(status.untracked, ["new file.txt"])
        XCTAssertEqual(status.unstaged, ["work.txt", "both.txt"])
        XCTAssertEqual(status.changed, ["staged only.txt", "work.txt", "both.txt"])
        XCTAssertTrue(WorktreeFork.parseStatus(Data("u UU N... 1 1 1 1 a b c f.txt\0".utf8)).unmerged)
    }

    func testBranchNames() {
        XCTAssertEqual(WorktreeFork.branchName(forking: "worktree/brave-river-1a2f", taken: [], seed: 0x9b3c),
                       "worktree/brave-river-1a2f-fork-9b3c")
        // A fork of a fork doesn't stack suffixes.
        XCTAssertEqual(WorktreeFork.branchName(forking: "worktree/brave-river-1a2f-fork-9b3c", taken: [], seed: 0x0001),
                       "worktree/brave-river-1a2f-fork-0001")
        XCTAssertEqual(WorktreeFork.branchName(forking: "fix/login", taken: [], seed: 0x00ab),
                       "worktree/fix-login-fork-00ab")
        XCTAssertEqual(WorktreeFork.branchName(forking: nil, taken: [], seed: 0x1234), "worktree/fork-1234")
        let first = WorktreeFork.branchName(forking: "main", taken: [], seed: 7)
        XCTAssertNotEqual(WorktreeFork.branchName(forking: "main", taken: [first], seed: 7), first)
    }

    // MARK: - The agent's half

    func testForkWords() {
        let id = "01a083f5-a13c-7b70-b215-1593799518d0"
        XCTAssertEqual(AgentConversation.forkWords(agent: "claude", id: id,
                                                   transcript: "/Users/x/.claude/projects/-Users-x-app/\(id).jsonl"),
                       ["--resume", "/Users/x/.claude/projects/-Users-x-app/\(id).jsonl", "--fork-session"])
        // A path a shell would have to read is not typed; the id is.
        XCTAssertEqual(AgentConversation.forkWords(agent: "claude", id: id, transcript: "/Users/x y/\(id).jsonl"),
                       ["--resume", id, "--fork-session"])
        XCTAssertEqual(AgentConversation.forkWords(agent: "pi", id: id), ["--fork", id])
        XCTAssertEqual(AgentConversation.forkWords(agent: "codex", id: id), ["fork", "-C", ".", id])
        XCTAssertNil(AgentConversation.forkWords(agent: "aider", id: id))
        XCTAssertNil(AgentConversation.forkWords(agent: "claude", id: "--dangerous"))
    }

    func testForkCommandsCarryFlagsButNotTheSourceFolder() {
        XCTAssertEqual(AgentCommandLine.command(agent: "claude", argv: "claude --model opus",
                                                resume: ["--resume", "abc", "--fork-session"]),
                       "claude --resume abc --fork-session --model opus")
        XCTAssertEqual(AgentCommandLine.command(agent: "codex", argv: "codex -m o3 -C /src/app --full-auto",
                                                resume: ["fork", "-C", ".", "abc"], excluding: ["--cd", "-C"]),
                       "codex fork -m o3 --full-auto -C . abc")
        XCTAssertEqual(AgentCommandLine.command(agent: "codex", argv: "codex --cd=/src/app",
                                                resume: ["fork", "-C", ".", "abc"], excluding: ["--cd", "-C"]),
                       "codex fork -C . abc")
        // No conversation known: the agent, fresh, with its flags.
        XCTAssertEqual(AgentCommandLine.command(agent: "claude", argv: "claude --model opus", resume: []),
                       "claude --model opus")
    }
}
