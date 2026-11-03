import XCTest

/// ⌘Y: three agents' history formats, read from the middle of a file, and
/// the ranking whose first row is the feature. Every fixture is synthetic,
/// shaped like the agents' files (see `PromptHistory` for the layouts).
final class PromptHistoryTests: XCTestCase {
    private typealias Entry = PromptHistory.Entry

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Claude Code

    func testClaudeLine() throws {
        let entry = try XCTUnwrap(PromptHistory.claudeEntry(line([
            "display": "make the sidebar faster", "pastedContents": [:],
            "timestamp": 1_760_000_000_123, "project": "/Users/someone/code/app", "sessionId": "abc",
        ])))
        XCTAssertEqual(entry.text, "make the sidebar faster")
        XCTAssertEqual(entry.agent, .claude)
        XCTAssertEqual(entry.directory, "/Users/someone/code/app")
        XCTAssertEqual(entry.date.timeIntervalSince1970, 1_760_000_000.123, accuracy: 0.001)
    }

    /// A paste is a placeholder in `display`; the text is inline or in the
    /// paste cache by hash, and a paste nobody can answer stays as it was.
    func testClaudePastesAreExpanded() throws {
        let entry = try XCTUnwrap(PromptHistory.claudeEntry(line([
            "display": "look at [Pasted text #1 +2 lines] and [Pasted text #2 +9 lines] then [Pasted text #3]",
            "pastedContents": [
                "1": ["id": 1, "type": "text", "content": "one\ntwo\nthree"],
                "2": ["id": 2, "type": "text", "contentHash": "beef"],
                "3": ["id": 3, "type": "text", "contentHash": "gone"],
            ],
            "timestamp": 1, "project": "/p",
        ]), paste: { $0 == "beef" ? "from the cache" : nil }))
        XCTAssertEqual(entry.text, "look at one\ntwo\nthree and from the cache then [Pasted text #3]")
    }

    func testImagesStayPlaceholders() throws {
        let entry = try XCTUnwrap(PromptHistory.claudeEntry(line([
            "display": "what is this [Image #1]",
            "pastedContents": ["1": ["id": 1, "type": "image", "content": "iVBOR"]],
            "timestamp": 1, "project": "/p",
        ])))
        XCTAssertEqual(entry.text, "what is this [Image #1]")
    }

    func testMalformedAndUnknownLinesAreSkipped() {
        XCTAssertNil(PromptHistory.claudeEntry(Data("{\"display\": \"cut off".utf8)))
        XCTAssertNil(PromptHistory.claudeEntry(line(["text": "renamed field", "timestamp": 1])))
        XCTAssertNil(PromptHistory.claudeEntry(line(["display": "no time"])))
        XCTAssertNil(PromptHistory.claudeEntry(Data("[1, 2]".utf8)))
    }

    func testBareSlashCommandsAndBlanksAreNotPrompts() {
        XCTAssertFalse(PromptHistory.isPrompt("/clear"))
        XCTAssertFalse(PromptHistory.isPrompt("  /model  "))
        XCTAssertFalse(PromptHistory.isPrompt("/plugin:command"))
        XCTAssertFalse(PromptHistory.isPrompt(" \n "))
        XCTAssertTrue(PromptHistory.isPrompt("/review the last commit"))
        XCTAssertTrue(PromptHistory.isPrompt("/Users/someone/notes.md is wrong"))
        XCTAssertTrue(PromptHistory.isPrompt("/tmp/x.log"))
        XCTAssertTrue(PromptHistory.isPrompt("!ls -la"))
    }

    // MARK: - Codex

    func testCodexLineAndRolloutHeader() throws {
        let entry = try XCTUnwrap(PromptHistory.codexEntry(line([
            "session_id": "0199-aa", "ts": 1_760_000_000, "text": "add a changelog page",
        ])))
        XCTAssertEqual(entry.text, "add a changelog page")
        XCTAssertEqual(entry.agent, .codex)
        XCTAssertNil(entry.directory)
        XCTAssertEqual(entry.conversation, "0199-aa")
        XCTAssertEqual(entry.date.timeIntervalSince1970, 1_760_000_000)

        XCTAssertEqual(PromptHistory.codexDirectory(fromRolloutHeader: line([
            "type": "session_meta", "payload": ["id": "0199-aa", "cwd": "/work/site", "base_instructions": ["text": "…"]],
        ])), "/work/site")
        XCTAssertNil(PromptHistory.codexDirectory(fromRolloutHeader: line(["type": "response_item", "payload": [:]])))
    }

    // MARK: - Pi

    func testPiMessages() throws {
        XCTAssertEqual(PromptHistory.piDirectory(fromHeader: line([
            "type": "session", "version": 3, "id": "x", "timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/work/pi",
        ])), "/work/pi")

        let parts = try XCTUnwrap(PromptHistory.piEntry(line([
            "type": "message", "id": "1", "parentId": "0", "timestamp": "2026-10-01T10:00:01.000Z",
            "message": ["role": "user", "timestamp": 1_759_312_801_000,
                        "content": [["type": "text", "text": "first part"], ["type": "image", "data": "…"],
                                    ["type": "text", "text": "second part"]]],
        ]), directory: "/work/pi"))
        XCTAssertEqual(parts.text, "first part\nsecond part")
        XCTAssertEqual(parts.agent, .pi)
        XCTAssertEqual(parts.directory, "/work/pi")
        XCTAssertEqual(parts.date.timeIntervalSince1970, 1_759_312_801)

        let string = try XCTUnwrap(PromptHistory.piEntry(line([
            "type": "message", "timestamp": "2026-10-01T10:00:01.500Z",
            "message": ["role": "user", "content": "plain string"],
        ]), directory: nil))
        XCTAssertEqual(string.text, "plain string")
        XCTAssertEqual(string.date.timeIntervalSince1970, 1_790_848_801.5, accuracy: 0.001, "from the entry's own stamp")

        XCTAssertNil(PromptHistory.piEntry(line([
            "type": "message", "timestamp": "2026-10-01T10:00:02.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "an answer"]], "timestamp": 1],
        ]), directory: nil))
        XCTAssertNil(PromptHistory.piEntry(line(["type": "model_change", "modelId": "m"]), directory: nil))
    }

    // MARK: - Reading from the middle

    func testATailDropsTheLineItStartedInside() {
        let data = Data("ay\": 1}\n{\"a\": 2}\n{\"a\": 3}\n".utf8)
        XCTAssertEqual(PromptHistory.lines(in: data, fromMiddle: true).map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\": 2}", "{\"a\": 3}"])
        XCTAssertEqual(PromptHistory.lines(in: data, fromMiddle: false).count, 3)
        // Started exactly on a line boundary: nothing to drop.
        XCTAssertEqual(PromptHistory.lines(in: Data("\n{\"a\": 2}\n".utf8), fromMiddle: true).count, 1)
    }

    // MARK: - Merging

    private func entry(_ text: String, _ agent: PromptHistory.Agent = .claude, at seconds: TimeInterval,
                       project: String? = "/work/app") -> Entry {
        Entry(text: text, agent: agent, directory: project, project: project, date: Date(timeIntervalSince1970: seconds))
    }

    func testMergedIsNewestFirstEachPromptOnce() {
        let merged = PromptHistory.merged([
            [entry("fix the build", at: 10), entry("write tests", at: 30)],
            [entry("fix the build\n", .codex, at: 20), entry("deploy", .codex, at: 5)],
        ], limit: 10)
        XCTAssertEqual(merged.map(\.text), ["write tests", "fix the build\n", "deploy"])
        XCTAssertEqual(merged[1].agent, .codex, "the newest copy is the one kept")
        XCTAssertEqual(PromptHistory.merged([[entry("a", at: 1), entry("b", at: 2), entry("c", at: 3)]],
                                            limit: 2).map(\.text), ["c", "b"])
    }

    // MARK: - Ranking

    private func rank(_ query: String, _ entries: [Entry], project: String? = "/work/app") -> [String] {
        PromptHistory.rank(query, in: PromptHistory.index(entries.sorted { $0.date > $1.date }),
                           project: project, limit: 50).map(\.entry.text)
    }

    func testEmptyQueryIsThisProjectFirstThenNewest() {
        let entries = [
            entry("elsewhere, newest", at: 40, project: "/work/other"),
            entry("here, older", at: 10),
            entry("here, newer", at: 30),
            entry("nowhere", at: 20, project: nil),
        ]
        XCTAssertEqual(rank("", entries), ["here, newer", "here, older", "elsewhere, newest", "nowhere"])
        XCTAssertEqual(rank("", entries, project: nil), ["elsewhere, newest", "here, newer", "nowhere", "here, older"])
    }

    func testEveryWordMustBeFound() {
        let entries = [entry("Refactor the git panel's diff view", at: 2), entry("refactor the sidebar", at: 1)]
        XCTAssertEqual(rank("refactor diff", entries), ["Refactor the git panel's diff view"])
        XCTAssertEqual(rank("REFACTOR", entries).count, 2, "case doesn't matter")
        XCTAssertEqual(rank("refactor nothing", entries), [])
    }

    func testAccentsDoNotMatter() {
        XCTAssertEqual(rank("cafe", [entry("open the Café menu", at: 1)]), ["open the Café menu"])
    }

    func testTyposAreForgiven() {
        let entries = [entry("commit the worktree changes", at: 1)]
        XCTAssertEqual(rank("comit", entries).count, 1, "a missing letter")
        XCTAssertEqual(rank("wrotkree", entries).count, 1, "two edits in a word of eight letters")
        XCTAssertEqual(rank("wrotkrea", entries).count, 0, "and no more")
        XCTAssertEqual(rank("worktere", entries).count, 1, "two letters swapped")
        XCTAssertEqual(rank("chnages", entries).count, 1)
        XCTAssertEqual(rank("worktreee", entries).count, 1, "one too many")
        XCTAssertEqual(rank("commi", entries).count, 1, "the start of a word")
        XCTAssertEqual(rank("wrokt", entries).count, 1, "a typo in the start of a word")
        XCTAssertEqual(rank("cmmit", entries).count, 1, "the second letter may be the wrong one")
    }

    func testTheFirstLetterAndShortWordsAreNotForgiven() {
        let entries = [entry("commit the worktree changes", at: 1)]
        XCTAssertEqual(rank("vommit", entries).count, 0, "the first letter is taken as typed")
        XCTAssertEqual(rank("ocmmit", entries).count, 1, "unless it's swapped with the second")
        XCTAssertEqual(rank("thx", entries).count, 0, "three letters must be exact")
    }

    func testAnExactMatchBeatsATypoWithinAProject() {
        let entries = [
            entry("fix the comit hook", at: 3),        // newest, but only a typo away
            entry("commit everything", at: 1),
            entry("commit elsewhere", at: 2, project: "/work/other"),
        ]
        XCTAssertEqual(rank("commit", entries), ["commit everything", "fix the comit hook", "commit elsewhere"])
    }

    func testTheProjectNameNarrows() {
        let entries = [entry("fix it", at: 2, project: "/work/wortel"), entry("fix it too", at: 1, project: "/work/site")]
        XCTAssertEqual(rank("fix wortel", entries, project: nil), ["fix it"])
    }

    func testAProjectInsideTheSessionsFolderIsHere() {
        XCTAssertTrue(PromptHistory.isProject("/work/app", inside: "/work/app"))
        XCTAssertTrue(PromptHistory.isProject("/work/app/web", inside: "/work/app"))
        XCTAssertFalse(PromptHistory.isProject("/work/app-web", inside: "/work/app"), "a sibling sharing a prefix")
        XCTAssertFalse(PromptHistory.isProject(nil, inside: "/work/app"))
    }

    func testOnlyTheStartOfALongPromptIsSearched() {
        let long = "start " + String(repeating: "x", count: PromptHistory.searchedLength) + " needle"
        XCTAssertEqual(rank("start", [entry(long, at: 1)]).count, 1)
        XCTAssertEqual(rank("needle", [entry(long, at: 1)]).count, 0)
    }

    func testRankingStopsWhenCancelled() {
        let index = PromptHistory.index((0..<1000).map { entry("prompt \($0)", at: TimeInterval($0)) })
        XCTAssertEqual(PromptHistory.rank("prompt", in: index, project: nil, limit: 10, isCancelled: { true }).count, 0)
        XCTAssertEqual(PromptHistory.rank("prompt", in: index, project: nil, limit: 10).count, 10)
    }

    // MARK: - Showing and typing

    func testSummaryIsTheFirstLineWithTextAndHowManyMore() {
        XCTAssertEqual(PromptHistory.summary("one line").line, "one line")
        XCTAssertEqual(PromptHistory.summary("one line").more, 0)
        let summary = PromptHistory.summary("\n  \nfirst\nsecond\r\nthird\n\n")
        XCTAssertEqual(summary.line, "first")
        XCTAssertEqual(summary.more, 2, "blank lines at the end don't count")
    }

    func testInsertionNeverSends() {
        XCTAssertEqual(PromptHistory.insertion("run it\n\n", bracketed: true), "run it")
        XCTAssertEqual(PromptHistory.insertion("one\r\ntwo\n", bracketed: true), "one\ntwo")
        XCTAssertEqual(PromptHistory.insertion("one\n\n  two  \nthree\n", bracketed: false), "one two three",
                       "unbracketed, a newline is Return")
        XCTAssertEqual(PromptHistory.insertion("single", bracketed: false), "single")
    }

    func testAge() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_762_000_000)   // 2025-11-01
        func age(_ ago: TimeInterval) -> String {
            PromptHistory.age(of: now.addingTimeInterval(-ago), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(age(5), "now")
        XCTAssertEqual(age(5 * 60), "5m")
        XCTAssertEqual(age(3 * 3600 + 59), "3h")
        XCTAssertEqual(age(2 * 86_400), "2d")
        XCTAssertEqual(age(20 * 86_400), "Oct 12")
        XCTAssertEqual(age(400 * 86_400), "Sep 2024")
    }

    func testProjectName() {
        XCTAssertEqual(PromptHistory.projectName("/work/wortel", home: "/Users/x"), "wortel")
        XCTAssertEqual(PromptHistory.projectName("/Users/x", home: "/Users/x"), "~")
        XCTAssertNil(PromptHistory.projectName(nil))
    }
}

/// The disk half: where each agent's files are, reading them bounded, and
/// reading only what changed.
final class PromptHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ lines: [[String: Any]], to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var locations: PromptHistoryStore.Locations {
        PromptHistoryStore.Locations(claude: root.appendingPathComponent("claude"),
                                     codex: root.appendingPathComponent("codex"),
                                     piSessions: root.appendingPathComponent("pi/sessions"))
    }

    func testLocationsFollowTheAgentsVariables() {
        let home = URL(fileURLWithPath: "/Users/x")
        let defaults = PromptHistoryStore.Locations.current(environment: [:], home: home)
        XCTAssertEqual(defaults.claude.path, "/Users/x/.claude")
        XCTAssertEqual(defaults.codex.path, "/Users/x/.codex")
        XCTAssertEqual(defaults.piSessions.path, "/Users/x/.pi/agent/sessions")
        let set = PromptHistoryStore.Locations.current(
            environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude", "CODEX_HOME": "/cfg/codex", "PI_CODING_AGENT_DIR": "/cfg/pi"],
            home: home)
        XCTAssertEqual(set.claude.path, "/cfg/claude")
        XCTAssertEqual(set.codex.path, "/cfg/codex")
        XCTAssertEqual(set.piSessions.path, "/cfg/pi/sessions")
    }

    func testLoadReadsAllThreeAgents() throws {
        let work = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try write([
            ["display": "claude prompt", "pastedContents": [:], "timestamp": 3_000_000, "project": work],
            ["display": "/clear", "pastedContents": [:], "timestamp": 3_500_000, "project": work],
            ["display": "with a paste [Pasted text #1 +1 lines]",
             "pastedContents": ["1": ["id": 1, "type": "text", "contentHash": "abc123"]],
             "timestamp": 3_600_000, "project": work],
        ], to: "claude/history.jsonl")
        try "pasted\ntext".write(to: root.appendingPathComponent("claude/paste-cache/abc123.txt").creatingDirectory(),
                                 atomically: true, encoding: .utf8)

        let codexDate = Date(timeIntervalSince1970: 2000)
        try write([["session_id": "c0de", "ts": 2000, "text": "codex prompt"]], to: "codex/history.jsonl")
        let day = Calendar.current.dateComponents([.year, .month, .day], from: codexDate)
        try write([["type": "session_meta", "payload": ["id": "c0de", "cwd": "/somewhere/codex"]]],
                  to: String(format: "codex/sessions/%04d/%02d/%02d/rollout-start-c0de.jsonl",
                             day.year!, day.month!, day.day!))

        try write([
            ["type": "session", "version": 3, "id": "p1", "timestamp": "1970-01-01T00:16:40.000Z", "cwd": "/somewhere/pi"],
            ["type": "message", "id": "m1", "timestamp": "1970-01-01T00:16:41.000Z",
             "message": ["role": "user", "timestamp": 1_001_000, "content": [["type": "text", "text": "pi prompt"]]]],
            ["type": "message", "id": "m2", "timestamp": "1970-01-01T00:16:42.000Z",
             "message": ["role": "assistant", "timestamp": 1_002_000, "content": []]],
        ], to: "pi/sessions/--somewhere-pi--/1970-01-01T00-16-40-000Z_p1.jsonl")

        let entries = PromptHistoryStore().load(from: locations)
        XCTAssertEqual(entries.map(\.text), ["with a paste pasted\ntext", "claude prompt", "codex prompt", "pi prompt"])
        XCTAssertEqual(entries.map(\.agent), [.claude, .claude, .codex, .pi])
        XCTAssertEqual(entries[2].directory, "/somewhere/codex", "from the rollout")
        XCTAssertEqual(entries[3].directory, "/somewhere/pi", "from the header")
        XCTAssertEqual(entries[1].project, (work as NSString).standardizingPath)
    }

    func testOnlyTheTailIsRead() throws {
        let url = root.appendingPathComponent("big.jsonl")
        try (String(repeating: "x", count: 1000) + "\nlast line\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = try XCTUnwrap(PromptHistoryStore.tail(of: url, maxBytes: 20))
        XCTAssertEqual(tail.data.count, 20)
        XCTAssertTrue(tail.fromMiddle)
        XCTAssertEqual(PromptHistory.lines(in: tail.data, fromMiddle: true).map { String(decoding: $0, as: UTF8.self) },
                       ["last line"])
        let whole = try XCTUnwrap(PromptHistoryStore.tail(of: url, maxBytes: 1 << 20))
        XCTAssertFalse(whole.fromMiddle)
    }

    func testAFileIsReadAgainOnlyWhenItChanges() throws {
        let store = PromptHistoryStore()
        try write([["display": "first", "timestamp": 1000, "project": "/p"]], to: "claude/history.jsonl")
        XCTAssertEqual(store.load(from: locations).map(\.text), ["first"])
        try write([["display": "first", "timestamp": 1000, "project": "/p"],
                   ["display": "second", "timestamp": 2000, "project": "/p"]], to: "claude/history.jsonl")
        XCTAssertEqual(store.load(from: locations).map(\.text), ["second", "first"])
    }

    func testMissingFilesAreNoHistory() {
        XCTAssertEqual(PromptHistoryStore().load(from: locations).count, 0)
    }
}

private extension URL {
    /// Self, with its parent folder made.
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
