import Foundation

/// Claude Code started in a Wortel shell opens in its fullscreen renderer,
/// unless the person chose a renderer themselves.
///
/// Claude Code's inline renderer prints its conversation into the terminal's
/// scrollback and redraws only the visible screen after that. So what it
/// printed while the terminal was narrow (the side column open on a small
/// window) stays wrapped at that width for good, and what it printed in one
/// appearance keeps those colours. Its fullscreen renderer draws the whole
/// conversation itself and redraws all of it at any width and for any
/// appearance. Measured on 2026-11-24, Claude Code 2.1.331 in a pty harness:
/// widened from 44 to 100 columns, inline redrew only the visible rows (Ctrl+L
/// the same), and only a restart with `--continue` reprinted the rest.
///
/// `CLAUDE_CODE_NO_FLICKER=1` is the same as `"tui": "fullscreen"` in Claude's
/// settings, but Claude reads the variable *before* that setting, so set
/// unconditionally it would override a person who chose `/tui classic`. It is
/// set only when Claude's user settings say nothing about `tui`, and when
/// nothing Wortel inherited already sets either of Claude's own switches.
/// Claude still turns fullscreen off by itself for screen readers and inside
/// tmux. Project settings (`.claude/settings.json` in a repository) are not
/// looked at: a shell's folder changes after it starts.
enum ClaudeRenderer {
    static let variable = "CLAUDE_CODE_NO_FLICKER"
    /// Claude's other switch, which turns the alternate screen (and so
    /// fullscreen) off.
    static let offSwitch = "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"

    /// What to add to a new shell's environment: the variable, or nothing.
    ///
    /// `settings` is Claude's user `settings.json`, nil when there is none.
    /// One that can't be read as JSON says nothing Wortel can trust, so the
    /// person is left with whatever Claude makes of it.
    static func environment(settings: Data?, inherited: [String: String]) -> [String: String] {
        if inherited[variable] != nil || inherited[offSwitch] != nil { return [:] }
        if let settings {
            guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any]
            else { return [:] }
            if object["tui"] != nil { return [:] }
        }
        return [variable: "1"]
    }

    /// Claude's user settings file: in `CLAUDE_CONFIG_DIR` when that is set,
    /// in `~/.claude` otherwise.
    static func settingsURL(inherited: [String: String], home: String = NSHomeDirectory()) -> URL {
        if let directory = inherited["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .appendingPathComponent("settings.json")
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
    }

    /// For a shell starting now. Read each time, so a `/tui` choice made in
    /// one session holds for every shell started after it.
    static func forNewShell(inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        let settings = try? Data(contentsOf: settingsURL(inherited: inherited))
        return environment(settings: settings, inherited: inherited)
    }
}
