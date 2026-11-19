import XCTest

/// When Wortel writes its skill into `~/.claude/skills`. Every wrong answer
/// is Wortel writing over something the person changed, or bringing back
/// something they removed.
final class AgentSkillTests: XCTestCase {
    private let v1 = Data("version one".utf8)
    private let v2 = Data("version two".utf8)
    private var wroteV1: String { AgentSkill.digest(v1) }

    func testInstalledOnceWhenClaudeIsThere() {
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: nil, bundled: v1, written: nil), .install)
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: false, onDisk: nil, bundled: v1, written: nil), .leave)
    }

    func testDeletedStaysDeleted() {
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: nil, bundled: v2, written: wroteV1), .leave)
    }

    func testUntouchedIsKeptUpToDate() {
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: v1, bundled: v2, written: wroteV1), .update)
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: v1, bundled: v1, written: wroteV1), .leave)
    }

    /// The same file arriving another way (a synced `~/.claude`) is taken as
    /// Wortel's, so a later update still reaches it.
    func testTheSameFileUnrecordedIsAdopted() {
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: v1, bundled: v1, written: nil), .adopt)
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: v1, bundled: v1, written: "older"), .adopt)
    }

    func testEditedIsThePersonsAndLeftAlone() {
        let edited = Data("version one, with my own line".utf8)
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: edited, bundled: v2, written: wroteV1), .leave)
        XCTAssertEqual(AgentSkill.decide(claudeInstalled: true, onDisk: edited, bundled: v2, written: nil), .leave,
                       "a skill of the same name Wortel never wrote")
    }

    /// The bundled skill: a name and description Claude can read, the move
    /// it must offer, and no em-dashes (it is read by people too).
    func testTheBundledSkill() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/wortel-skill.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: wortel\ndescription: "))
        XCTAssertTrue(text.contains("wortel cd"))
        XCTAssertFalse(text.contains("\u{2014}"))
        XCTAssertFalse(text.contains("\u{2013}"))
    }
}
