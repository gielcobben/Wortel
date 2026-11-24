import XCTest

/// Claude Code opens fullscreen in Wortel unless the person chose otherwise.
/// The variable beats Claude's own setting, so every way a choice can show
/// must keep it out.
final class ClaudeRendererTests: XCTestCase {
    private func env(_ json: String?, inherited: [String: String] = [:]) -> [String: String] {
        ClaudeRenderer.environment(settings: json.map { Data($0.utf8) }, inherited: inherited)
    }

    func testNoSettingsFileIsFullscreen() {
        XCTAssertEqual(env(nil), ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    func testSettingsWithoutTuiIsFullscreen() {
        XCTAssertEqual(env(#"{"model": "opus", "voice": {"enabled": true}}"#),
                       ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    func testAChosenRendererIsLeftAlone() {
        XCTAssertEqual(env(#"{"tui": "default"}"#), [:])
        XCTAssertEqual(env(#"{"tui": "fullscreen"}"#), [:])
    }

    func testUnreadableSettingsAreLeftAlone() {
        XCTAssertEqual(env("{ not json"), [:])
        XCTAssertEqual(env("[1, 2]"), [:])
    }

    func testAnInheritedSwitchIsLeftAlone() {
        XCTAssertEqual(env(nil, inherited: ["CLAUDE_CODE_NO_FLICKER": "0"]), [:])
        XCTAssertEqual(env(nil, inherited: ["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"]), [:])
    }

    func testSettingsFileFollowsClaudeConfigDir() {
        XCTAssertEqual(ClaudeRenderer.settingsURL(inherited: [:], home: "/Users/me").path,
                       "/Users/me/.claude/settings.json")
        XCTAssertEqual(ClaudeRenderer.settingsURL(inherited: ["CLAUDE_CONFIG_DIR": "/cfg"], home: "/Users/me").path,
                       "/cfg/settings.json")
    }
}
