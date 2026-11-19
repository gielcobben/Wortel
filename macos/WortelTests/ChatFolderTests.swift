import XCTest

/// Where an agent session that would start in the home folder starts instead.
/// Each wrong answer is a trust question at every start, or two agents in
/// one folder.
final class ChatFolderTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "chatfolder-\(UUID().uuidString)/Wortel"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    private let home = "/Users/someone"

    private func config(_ trusted: [String: Bool]) -> Data {
        let projects = trusted.mapValues { ["hasTrustDialogAccepted": $0] }
        return try! JSONSerialization.data(withJSONObject: ["projects": projects])
    }

    // MARK: - Which sessions get one

    func testHomeAndNoDirectoryAtAllGetOne() {
        XCTAssertTrue(ChatFolder.wantsOwnFolder(nil, home: home, root: home + "/Wortel"))
        XCTAssertTrue(ChatFolder.wantsOwnFolder(home, home: home, root: home + "/Wortel"))
        XCTAssertTrue(ChatFolder.wantsOwnFolder(home + "/", home: home, root: home + "/Wortel"))
    }

    /// ⌘N beside an agent's folder: a new one, not a second agent in it.
    func testTheParentAndEveryFolderInItGetANewOne() {
        let wortel = home + "/Wortel"
        XCTAssertTrue(ChatFolder.wantsOwnFolder(wortel, home: home, root: wortel))
        XCTAssertTrue(ChatFolder.wantsOwnFolder(wortel + "/2026-11-19/3", home: home, root: wortel))
    }

    func testAProjectKeepsItsFolder() {
        let wortel = home + "/Wortel"
        XCTAssertFalse(ChatFolder.wantsOwnFolder(home + "/Developer/app", home: home, root: wortel))
        XCTAssertFalse(ChatFolder.wantsOwnFolder(home + "/Wortel-site", home: home, root: wortel),
                       "a sibling whose name starts the same is not inside")
        XCTAssertFalse(ChatFolder.wantsOwnFolder("/Users", home: home, root: wortel))
    }

    // MARK: - Making it

    func testFoldersAreNumberedPerDayFromOne() throws {
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        let name = ChatFolder.dayName(day)
        XCTAssertEqual(ChatFolder.nextFolder(in: root, now: day), "\(root!)/\(name)/1")
        XCTAssertEqual(ChatFolder.nextFolder(in: root, now: day), "\(root!)/\(name)/2")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root!)/\(name)/2", isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// One removed by hand is not handed out again: Claude still has a
    /// conversation filed under its path.
    func testANumberIsNeverReusedWhileAHigherOneIsThere() throws {
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        _ = ChatFolder.nextFolder(in: root, now: day)
        let second = try XCTUnwrap(ChatFolder.nextFolder(in: root, now: day))
        _ = ChatFolder.nextFolder(in: root, now: day)
        try FileManager.default.removeItem(atPath: second)
        XCTAssertEqual(ChatFolder.nextFolder(in: root, now: day).map { ($0 as NSString).lastPathComponent }, "4")
    }

    func testTheDayIsTheMacsOwn() {
        let date = Date(timeIntervalSince1970: 1_795_032_000) // 2026-11-18 about 20:00 UTC
        XCTAssertEqual(ChatFolder.dayName(date, timeZone: TimeZone(identifier: "UTC")!), "2026-11-18")
        XCTAssertEqual(ChatFolder.dayName(date, timeZone: TimeZone(identifier: "Europe/Amsterdam")!), "2026-11-18")
        XCTAssertEqual(ChatFolder.dayName(date, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-11-19")
    }

    // MARK: - Trust

    /// Until the parent is trusted, Claude starts in the parent and asks
    /// there, once. After that, a folder of its own that never asks.
    func testClaudeStartsInTheParentUntilItIsTrusted() throws {
        let untrusted = ChatFolder.make(for: "claude", root: root, claudeConfig: { self.config([:]) })
        XCTAssertEqual(untrusted, root)
        let trusted = try XCTUnwrap(ChatFolder.make(
            for: "claude --model opus", root: root, claudeConfig: { self.config([self.realRoot: true]) }))
        XCTAssertEqual((trusted as NSString).lastPathComponent, "1")
    }

    func testAnUnreadableConfigCountsAsNotTrusted() {
        XCTAssertEqual(ChatFolder.make(for: "claude", root: root, claudeConfig: { nil }), root)
        XCTAssertEqual(ChatFolder.make(for: "claude", root: root, claudeConfig: { Data("{".utf8) }), root)
    }

    /// Another agent has no trust question of Claude's: straight to its own.
    func testAnotherAgentGoesStraightToItsOwnFolder() throws {
        let path = try XCTUnwrap(ChatFolder.make(for: "codex", root: root, claudeConfig: { nil }))
        XCTAssertEqual((path as NSString).lastPathComponent, "1")
    }

    /// As Claude looks outside a git repository: the folder, or any above it.
    func testTrustAboveCounts() {
        let config = config(["/Users/someone/Developer": true, "/Users/someone": false])
        XCTAssertTrue(ChatFolder.claudeTrusts("/Users/someone/Developer/app", config: config))
        XCTAssertTrue(ChatFolder.claudeTrusts("/Users/someone/Developer", config: config))
        XCTAssertFalse(ChatFolder.claudeTrusts("/Users/someone/Wortel", config: config))
        XCTAssertFalse(ChatFolder.claudeTrusts("/Users/someone/Developer-old", config: config))
    }

    // MARK: - The command

    func testWhichCommandIsClaude() {
        XCTAssertTrue(ChatFolder.isClaude("claude"))
        XCTAssertTrue(ChatFolder.isClaude("claude --model opus"))
        XCTAssertTrue(ChatFolder.isClaude("/opt/homebrew/bin/claude"))
        XCTAssertFalse(ChatFolder.isClaude("codex"))
        XCTAssertFalse(ChatFolder.isClaude(""))
    }

    func testTheSessionIsNamedForItsAgent() {
        XCTAssertEqual(ChatFolder.sessionName(for: "claude --model opus"), "Claude")
        XCTAssertEqual(ChatFolder.sessionName(for: "/usr/local/bin/codex"), "Codex")
    }

    /// `root` with links resolved: `/var` is `/private/var`, and Claude keys
    /// its records by the real path.
    private var realRoot: String {
        URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }
}
