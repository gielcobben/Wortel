import XCTest

/// The agents known by name, in Swift and in the shell integration. The
/// shell has the list six times (two classifiers in each of three shells,
/// which cannot share a file), and "kept in step by hand" has been the whole
/// arrangement. This is the check.
final class AgentCommandsTests: XCTestCase {
    private static var shellIntegration: URL {
        URL(fileURLWithPath: #filePath)     // …/macos/WortelTests/AgentCommandsTests.swift
            .deletingLastPathComponent()    // …/macos/WortelTests
            .deletingLastPathComponent()    // …/macos
            .appendingPathComponent("Resources/ghostty/shell-integration")
    }

    private func occurrences(of list: String, in file: String) throws -> Int {
        let text = try String(contentsOf: Self.shellIntegration.appendingPathComponent(file), encoding: .utf8)
        return text.components(separatedBy: list).count - 1
    }

    func testZshAndBashNameTheSameAgentsInBothClassifiers() throws {
        let list = AgentCommands.detected.joined(separator: "|") + ")"
        XCTAssertEqual(try occurrences(of: list, in: "zsh/ghostty-integration"), 2)
        XCTAssertEqual(try occurrences(of: list, in: "bash/ghostty.bash"), 2)
    }

    func testFishNamesTheSameAgentsInBothClassifiers() throws {
        let list = "case " + AgentCommands.detected.joined(separator: " ") + "\n"
        XCTAssertEqual(
            try occurrences(of: list, in: "fish/vendor_conf.d/ghostty-shell-integration.fish"), 2)
    }

    func testEveryAgentIsCountedUnderItsOwnName() {
        for command in AgentCommands.detected {
            XCTAssertNotEqual(AgentName(command: command), .other, "\(command) is detected but unmapped")
        }
    }

    /// Typed bare, these two print their usage and exit.
    func testThePullDownLeavesOutWhatASessionCannotStartWith() {
        XCTAssertFalse(AgentCommands.offered.contains("ollama"))
        XCTAssertFalse(AgentCommands.offered.contains("llm"))
        XCTAssertEqual(AgentCommands.offered.count, AgentCommands.detected.count - 2)
        XCTAssertEqual(AgentCommands.offered.first, "claude")
    }

    /// What a worktree session started with it is called until it names itself.
    func testTheAgentALineStartsIsFoundByName() {
        XCTAssertEqual(AgentCommands.agent(in: "claude\n"), "claude")
        XCTAssertEqual(AgentCommands.agent(in: "devx claude --model opus"), "claude")
        XCTAssertEqual(AgentCommands.agent(in: "FOO=1 /usr/local/bin/codex"), "codex")
        XCTAssertNil(AgentCommands.agent(in: "npm run dev"))
        XCTAssertNil(AgentCommands.agent(in: ""))
    }
}
