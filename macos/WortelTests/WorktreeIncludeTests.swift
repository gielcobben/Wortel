import XCTest

/// The ignored files a new worktree gets copied in. Two halves, both silent
/// when wrong: the pattern language (a `.worktreeinclude` written for git or
/// another tool must select the same files here; git itself is the oracle),
/// and the copy (never into a nested repository, never over a file, never
/// past the budget).
final class WorktreeIncludeTests: XCTestCase {
    private var repo: URL!

    override func setUp() {
        repo = GitFixture.newRepo("include")
    }

    override func tearDown() {
        GitFixture.destroy(repo)
    }

    private func write(_ path: String, _ text: String = "x", in base: URL? = nil) {
        let url = (base ?? repo).appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Patterns, against git

    /// The same patterns as a `.gitignore`, and git's own verdict on every path.
    func testPatternsSelectWhatGitWouldIgnore() {
        let patterns = [
            "# comment", "", ".env*", "!.env.example", "config/local.json", "/build",
            "*.key", "secrets/", "**/cache/*.bin", "docs/**/draft.md", "a?c.txt", "[ab].log",
            "logs/**", "\\#hash",
        ]
        let paths = [
            ".env", ".env.local", ".env.example", "app/.env", "app/.envrc", "config/local.json",
            "app/config/local.json", "build/out.o", "app/build/out.o", "x.key", "deep/x.key",
            "secrets/a.txt", "app/secrets/b.txt", "deep/cache/z.bin", "cache/y.bin", "cache/y.txt",
            "docs/draft.md", "docs/a/b/draft.md", "abc.txt", "abbc.txt", "a.log", "c.log",
            "logs/x/y.txt", "#hash", "README.md",
        ]
        write(".gitignore", patterns.joined(separator: "\n") + "\n")
        for path in paths { write(path) }
        let ignored = Set(GitFixture.sh(
            "printf '%s\\n' \(paths.map(GitFixture.shellQuoted).joined(separator: " ")) | git check-ignore --no-index --stdin",
            in: repo).split(separator: "\n").map(String.init))
        XCTAssertFalse(ignored.isEmpty, "the oracle said nothing")
        let matcher = IgnorePatterns(lines: patterns)
        for path in paths {
            XCTAssertEqual(matcher.matches(path, isDirectory: false), ignored.contains(path), path)
        }
    }

    func testDirectoryOnlyPatternNeedsADirectory() {
        let matcher = IgnorePatterns(lines: ["out/"])
        XCTAssertTrue(matcher.matches("out", isDirectory: true))
        XCTAssertFalse(matcher.matches("out", isDirectory: false))
        XCTAssertTrue(matcher.matches("app/out/x.js", isDirectory: false))
    }

    // MARK: - Planning

    /// `.env*` reaches no further than git's listing: an ignored directory is
    /// one entry, and an unanchored pattern never looks inside it.
    func testDefaultPlanSkipsIgnoredDirectories() {
        let candidates = [".env", "node_modules/", ".claude/", ".claude/worktrees/", "app/.env.local",
                          "dist/", ".git/info"]
        let plan = WorktreeInclude.plan(candidates: candidates,
                                        patterns: WorktreeInclude.patterns(fileText: nil))
        XCTAssertEqual(plan.items.map(\.path), [".env", "app/.env.local"])
        XCTAssertEqual(plan.descend, [])
    }

    func testDirectoryPatternTakesTheDirectoryWhole() {
        let plan = WorktreeInclude.plan(candidates: [".claude/", ".claude/worktrees/"],
                                        patterns: IgnorePatterns(lines: [".claude/"]))
        XCTAssertEqual(plan.items, [WorktreeInclude.Item(path: ".claude", isDirectory: true)])
    }

    /// An anchored pattern naming a path inside an ignored directory is the
    /// one reason to look inside it, and then only what it names is taken.
    func testAnchoredPatternLooksInsideItsDirectory() {
        let patterns = IgnorePatterns(lines: ["vendor/config/*.yml"])
        let plan = WorktreeInclude.plan(candidates: ["vendor/", "node_modules/"], patterns: patterns)
        XCTAssertEqual(plan.items, [])
        XCTAssertEqual(plan.descend, ["vendor"])
        let inside = WorktreeInclude.plan(inside: "vendor",
                                          contents: ["config/", "config/a.yml", "config/b.txt", "x.yml"],
                                          patterns: patterns)
        XCTAssertEqual(inside.map(\.path), ["vendor/config/a.yml"])
    }

    // MARK: - Copying, end to end

    private func worktree() -> URL {
        GitFixture.sh("git commit -q --allow-empty -m init", in: repo)
        let target = repo.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        GitFixture.sh("git worktree add -q -b wt \(GitFixture.shellQuoted(target.path))", in: repo)
        addTeardownBlock { GitFixture.destroy(target) }
        return target
    }

    func testCopiesDefaultEnvFilesAndNothingElse() async throws {
        write(".gitignore", ".env*\nnode_modules/\n")
        write(".env", "SECRET=1")
        write("apps/web/.env.local", "WEB=1")
        write("apps/web/index.js")
        write("node_modules/pkg/.env", "NOPE=1")
        GitFixture.sh("git add .gitignore apps/web/index.js", in: repo)
        let target = worktree()
        let report = await WorktreeInclude.copy(from: repo.path, to: target.path)
        XCTAssertTrue(report.usedDefault)
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".env"), encoding: .utf8), "SECRET=1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("apps/web/.env.local").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("node_modules").path))
    }

    func testWorktreeIncludeFileIsHonoured() async throws {
        write(".gitignore", ".env*\nconfig/local.json\n.cache/\n")
        write(".worktreeinclude", "config/local.json\n")
        write(".env", "no")
        write("config/local.json", "{}")
        GitFixture.sh("git add .gitignore .worktreeinclude", in: repo)
        let target = worktree()
        let report = await WorktreeInclude.copy(from: repo.path, to: target.path)
        XCTAssertFalse(report.usedDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("config/local.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".env").path))
    }

    /// A file already in the worktree is the branch's; it is never replaced.
    func testNeverOverwrites() async throws {
        write(".gitignore", ".env\n")
        write(".env", "source")
        GitFixture.sh("git add .gitignore", in: repo)
        let target = worktree()
        write(".env", "already here", in: target)
        let report = await WorktreeInclude.copy(from: repo.path, to: target.path)
        XCTAssertEqual(report.skippedExisting, 1)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".env"), encoding: .utf8), "already here")
    }

    func testNestedRepositoryIsSkippedWithAWarning() async throws {
        write(".gitignore", "vendor/\n")
        write(".worktreeinclude", "vendor/\n")
        write("vendor/lib/README", "inner")
        GitFixture.sh("git init -q vendor/lib", in: repo)
        GitFixture.sh("git add .gitignore .worktreeinclude", in: repo)
        let target = worktree()
        let report = await WorktreeInclude.copy(from: repo.path, to: target.path)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("vendor"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("vendor").path))
    }

    func testSymlinkStaysASymlink() async throws {
        write(".gitignore", ".env*\n")
        write("real.env.txt", "r")
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent(".env").path,
                                                   withDestinationPath: "real.env.txt")
        GitFixture.sh("git add .gitignore real.env.txt", in: repo)
        let target = worktree()
        _ = await WorktreeInclude.copy(from: repo.path, to: target.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: target.appendingPathComponent(".env").path), "real.env.txt")
    }

    func testBudgetStopsTheCopy() {
        var report = WorktreeInclude.Report()
        let source = repo.appendingPathComponent("src")
        let target = repo.appendingPathComponent("dst")
        // One more file than the budget allows, in one directory.
        let big = source.appendingPathComponent("big")
        try? FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0...WorktreeInclude.entryBudget {
            FileManager.default.createFile(atPath: big.appendingPathComponent("\(i)").path, contents: nil)
        }
        WorktreeInclude.copy([WorktreeInclude.Item(path: "big", isDirectory: true)],
                             from: source.path, to: target.path, into: &report)
        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("big").path))
    }
}
