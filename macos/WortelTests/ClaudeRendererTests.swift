import XCTest

/// Claude Code opens fullscreen in Wortel unless the person chose otherwise
/// or Claude turned it off on this Mac. The variable beats Claude's own
/// setting and its own safety switch, so every way either can show must keep
/// it out.
final class ClaudeRendererTests: XCTestCase {
    private func env(_ json: String?, global: String? = nil,
                     inherited: [String: String] = [:]) -> [String: String] {
        ClaudeRenderer.environment(settings: json.map { Data($0.utf8) },
                                   globalConfig: global.map { Data($0.utf8) },
                                   inherited: inherited)
    }

    func testNoSettingsFileIsFullscreen() {
        XCTAssertEqual(env(nil), ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    func testSettingsWithoutTuiIsFullscreen() {
        XCTAssertEqual(env(#"{"model": "opus", "voice": {"enabled": true}}"#,
                           global: #"{"numStartups": 4, "fullscreenUpsellSeenCount": 3}"#),
                       ["CLAUDE_CODE_NO_FLICKER": "1"])
    }

    func testAChosenRendererIsLeftAlone() {
        XCTAssertEqual(env(#"{"tui": "default"}"#), [:])
        XCTAssertEqual(env(#"{"tui": "fullscreen"}"#), [:])
    }

    func testFullscreenClaudeTurnedOffIsLeftAlone() {
        let global = #"{"numStartups": 4, "fullscreenAutoDisabled": {"version": "2.1.331", "at": 1}}"#
        XCTAssertEqual(env(nil, global: global), [:])
    }

    func testUnreadableSettingsAreLeftAlone() {
        XCTAssertEqual(env("{ not json"), [:])
        XCTAssertEqual(env("[1, 2]"), [:])
    }

    func testAnInheritedSwitchIsLeftAlone() {
        XCTAssertEqual(env(nil, inherited: ["CLAUDE_CODE_NO_FLICKER": "0"]), [:])
        XCTAssertEqual(env(nil, inherited: ["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"]), [:])
    }

    func testFilesFollowClaudeConfigDir() {
        XCTAssertEqual(ClaudeRenderer.settingsURL(inherited: [:], home: "/Users/me").path,
                       "/Users/me/.claude/settings.json")
        XCTAssertEqual(ClaudeRenderer.globalConfigURL(inherited: [:], home: "/Users/me").path,
                       "/Users/me/.claude.json")
        let dir = ["CLAUDE_CONFIG_DIR": "/cfg"]
        XCTAssertEqual(ClaudeRenderer.settingsURL(inherited: dir, home: "/Users/me").path, "/cfg/settings.json")
        XCTAssertEqual(ClaudeRenderer.globalConfigURL(inherited: dir, home: "/Users/me").path, "/cfg/.claude.json")
    }
}
