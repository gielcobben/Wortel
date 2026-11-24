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
            ("status failed", report { $0.statusFailed = true }),
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

    // MARK: - wortel close

    /// Asked for by name, the changes the person said yes to don't keep it.
    func testAskedGoesWithTheChangesSaidYesTo() {
        let dirty = report { $0.changedFiles = ["screenshots/", "notes.txt"] }
        XCTAssertEqual(WorktreeCloseDecision.decideAsked(dirty, accepting: ["screenshots/", "notes.txt"]),
                       .remove(deleteBranch: true))
        XCTAssertEqual(WorktreeCloseDecision.decideAsked(dirty, accepting: []), .keep)
    }

    /// A change made after the question was answered was never shown.
    func testAskedKeepsForAChangeMadeSince() {
        let dirty = report { $0.changedFiles = ["screenshots/", "late.txt"] }
        XCTAssertEqual(WorktreeCloseDecision.decideAsked(dirty, accepting: ["screenshots/"]), .keep)
    }

    /// Commits of its own stay on the branch, which stays; the folder goes.
    func testAskedTakesTheFolderAndLeavesABranchWithItsOwnCommits() {
        XCTAssertEqual(WorktreeCloseDecision.decideAsked(report { $0.uniqueCommits = 2 }, accepting: []),
                       .remove(deleteBranch: false))
        XCTAssertEqual(WorktreeCloseDecision.decideAsked(report { $0.uniqueCommits = nil }, accepting: []),
                       .remove(deleteBranch: false))
    }

    /// Everything else that keeps on a click keeps when asked, yes or not.
    func testAskedStillKeepsWhatAYesCantAnswer() {
        let cases: [(String, WorktreeReport)] = [
            ("in use", report { $0.usedBy = ["node, running there"] }),
            ("locked", report { $0.isLocked = true }),
            ("status failed", report { $0.statusFailed = true }),
            ("not Wortel's", report { $0.isOwned = false }),
            ("missing", report { $0.isMissing = true }),
            ("not a checkout", report { $0.isOrphanedFolder = true }),
            ("a primary", report { $0.isPrimaryCheckout = true }),
            ("detached with commits", report { $0.branch = nil; $0.uniqueCommits = 1 }),
        ]
        for (name, report) in cases {
            XCTAssertEqual(WorktreeCloseDecision.decideAsked(report, accepting: Set(report.changedFiles)),
                           .keep, name)
        }
    }

    /// Only a question whose yes would change something is asked.
    func testChangesAreAskedOnlyWhenTheyAreAllThatKeepsIt() {
        XCTAssertEqual(WorktreeCloseDecision.changesToAsk(report()), [])
        XCTAssertEqual(WorktreeCloseDecision.changesToAsk(report { $0.changedFiles = ["a.txt"] }), ["a.txt"])
        XCTAssertEqual(WorktreeCloseDecision.changesToAsk(report { $0.changedFiles = ["a.txt"]; $0.isOwned = false }),
                       [])
        XCTAssertEqual(WorktreeCloseDecision.changesToAsk(report { $0.changedFiles = ["a.txt"]; $0.isLocked = true }),
                       [])
    }

    /// What the agent and the person read.
    func testTheWordsSayWhatHappensAndHaveNoDashes() {
        let waiting = PendingClose.acceptedMessage(waitsForTurn: true, worktreeIsWortels: true)
        XCTAssertTrue(waiting.hasPrefix("This session closes when your turn ends."))
        XCTAssertTrue(waiting.contains("Don't remove the worktree"))
        XCTAssertTrue(PendingClose.acceptedMessage(waitsForTurn: false, worktreeIsWortels: false)
            .contains("Wortel didn't make its worktree"))
        XCTAssertEqual(PendingClose.acceptedMessage(waitsForTurn: false, worktreeIsWortels: nil),
                       "Closing this session.")
        let detail = TrashChangesQuestion.detail(changes: ["screenshots/", "a", "b", "c", "d"])
        XCTAssertTrue(detail.contains("5 files that aren\u{2019}t committed: screenshots/, a, b and 2 more."))
        XCTAssertTrue(TrashChangesQuestion.detail(changes: ["a"]).contains("1 file that isn\u{2019}t committed: a."))
        for text in [waiting, detail, TrashChangesQuestion.title(session: "x")] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
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

    /// A file that isn't a list (damaged, or a newer build's) is set aside,
    /// not read as empty and written over by the next archive.
    func testAnUnreadableFileIsSetAside() throws {
        try Data("{\"version\": 2}".utf8).write(to: file)
        XCTAssertTrue(ArchiveStore.load(from: file).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let folder = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(stem + ".unreadable-") }
        XCTAssertEqual(aside.count, 1)
        for name in aside { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}
