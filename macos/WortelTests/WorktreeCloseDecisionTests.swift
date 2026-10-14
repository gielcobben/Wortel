import XCTest

/// What closing a worktree session does to its worktree. Removing is
/// automatic, so this is the one place a wrong answer throws work away with
/// no one asked: every case that isn't plainly nothing-to-keep must keep.
final class WorktreeCloseDecisionTests: XCTestCase {
    private func report(_ change: (inout WorktreeReport) -> Void = { _ in }) -> WorktreeReport {
        var report = WorktreeReport(path: "/w/app/fix")
        report.repoRoot = "/r/app"
        report.branch = "worktree/fix"
        report.isOwned = true
        report.createdBranch = true
        report.uniqueCommits = 0
        change(&report)
        return report
    }

    func testCleanAndNothingUniqueGoesWithItsBranch() {
        XCTAssertEqual(WorktreeCloseDecision.decide(report()), .remove(deleteBranch: true))
    }

    func testMergedByContentGoesToo() {
        let merged = report { $0.uniqueCommits = 3; $0.mergedInto = "origin/main" }
        XCTAssertEqual(WorktreeCloseDecision.decide(merged), .remove(deleteBranch: true))
    }

    /// A branch you checked out yourself: the worktree can go, never the branch.
    func testABranchWortelDidntMakeIsKept() {
        let theirs = report { $0.branch = "fix-login"; $0.createdBranch = false }
        XCTAssertEqual(WorktreeCloseDecision.decide(theirs), .remove(deleteBranch: false))
    }

    func testEverythingWorthKeepingKeeps() {
        let cases: [(String, WorktreeReport)] = [
            ("unique commits", report { $0.uniqueCommits = 2 }),
            ("unknown commits", report { $0.uniqueCommits = nil }),
            ("changes", report { $0.changedFiles = ["README.md"] }),
            ("untracked", report { $0.changedFiles = ["notes.txt"] }),
            ("in use", report { $0.usedBy = ["node, running there"] }),
            ("locked", report { $0.isLocked = true }),
            ("not Wortel's", report { $0.isOwned = false }),
            ("missing", report { $0.isMissing = true }),
            ("not a checkout", report { $0.isOrphanedFolder = true }),
            ("a primary", report { $0.isPrimaryCheckout = true }),
            ("detached with commits", report { $0.branch = nil; $0.uniqueCommits = 1 }),
        ]
        for (name, report) in cases {
            XCTAssertEqual(WorktreeCloseDecision.decide(report), .keep, name)
        }
    }
}

/// `archived-sessions.json`: what Restore brings back. Lenient by entry, so
/// one bad record never costs the rest.
final class ArchivedSessionStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-archive-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func entry(_ name: String) -> PersistedSession {
        PersistedSession(id: UUID(), name: name, title: "zsh", cwd: "/w/app/fix", originCwd: "/w/app/fix",
                         selected: false, nameSource: "agent", worktreeBranch: "worktree/fix",
                         gitPanelVisible: true, runningAgent: "claude", runningConversationID: "abc",
                         lastConversationID: "abc", portBase: 21_000)
    }

    func testRoundTrip() throws {
        let archived = [ArchivedSession(session: entry("App/Fix login"), archivedAt: Date(timeIntervalSince1970: 1000),
                                        checkout: "/w/app/fix", repoHome: "/r/app", isOwned: true)]
        ArchiveStore.save(archived, to: file)
        let loaded = ArchiveStore.load(from: file)
        XCTAssertEqual(loaded.count, 1)
        let item = try XCTUnwrap(loaded.first)
        XCTAssertEqual(item.folderPath, "App")
        XCTAssertEqual(item.leafName, "Fix login")
        XCTAssertEqual(item.branch, "worktree/fix")
        XCTAssertEqual(item.session.runningAgent, "claude")
        XCTAssertEqual(item.session.runningConversationID, "abc")
        XCTAssertEqual(item.archivedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(item.isOwned)
    }

    /// Missing fields default to the safe reading: not Wortel's, archived now.
    func testMissingFieldsAndABadEntry() throws {
        let good = try JSONEncoder().encode(entry("Kept"))
        let json = """
            [{"session": \(String(decoding: good, as: UTF8.self)), "checkout": "/w/app/kept"},
             {"session": {"nonsense": true}, "checkout": "/w/x"},
             {"checkout": "/w/no-session"}]
            """
        try Data(json.utf8).write(to: file)
        let loaded = ArchiveStore.load(from: file)
        XCTAssertEqual(loaded.map(\.leafName), ["Kept"])
        XCTAssertFalse(loaded[0].isOwned)
        XCTAssertNil(loaded[0].repoHome)
    }

    func testNothingLeftRemovesTheFile() {
        ArchiveStore.save([ArchivedSession(session: entry("A"), archivedAt: Date(), checkout: "/w/a",
                                           repoHome: nil, isOwned: true)], to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        ArchiveStore.save([], to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(ArchiveStore.load(from: file).isEmpty)
    }
}
