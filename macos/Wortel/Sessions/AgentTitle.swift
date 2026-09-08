import Foundation

/// Reads a session name out of the terminal title an agent CLI sets.
///
/// Claude Code names its own conversations: the moment you send a first prompt
/// it asks a small model for a title ("Debug git panel display issues with
/// worktrees"), keeps it for the life of the conversation, and pushes it into
/// the terminal title as `✳ <title>` at rest and `◐ <title>` (animated glyph)
/// while working. `/rename` replaces the text; a new conversation gets a new
/// one. That is exactly the name a sidebar row wants, arriving seconds after
/// the first prompt, generated from the conversation rather than from a screen
/// scrape, and it costs no model call of ours. So the title is the first
/// source of a session's name, and this is the parser.
///
/// The leading glyph is the tell. A shell's own title (`user@host: ~/dir`, or
/// the running command) never starts with one, so a title without a marker is
/// not an agent's and is ignored rather than adopted. What follows the marker
/// still needs a filter: some agents put *state* there ("✦ Working", "◇ Ready",
/// "✋ Action Required"), which would otherwise become a session called
/// "Working".
///
/// Pure and Foundation-only so `AgentTitleTests` can pin it without the app
/// shell: a wrong parse doesn't throw, it renames a session to a spinner frame.
enum AgentTitle {
    /// The name an agent's title carries, or nil when `title` is not an
    /// agent-authored title, or carries state rather than a name.
    ///
    /// `placeholder` is the name the session would have anyway (its directory);
    /// an agent that echoes that back has not said anything worth renaming for.
    static func sessionName(fromTitle title: String, placeholder: String? = nil) -> String? {
        var scalars = title.unicodeScalars[...]
        var markers = 0
        while let first = scalars.first {
            if isMarker(first) {
                markers += 1
            } else if !CharacterSet.whitespaces.contains(first) {
                break
            }
            scalars.removeFirst()
        }
        guard markers > 0 else { return nil }

        let name = String(Substring(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !name.isEmpty else { return nil }
        guard !isState(name) else { return nil }
        if let placeholder, name == placeholder { return nil }
        return name
    }

    /// The glyphs agent CLIs lead their titles with. Claude Code has used a
    /// braille spinner, the half-circle frames, and the dingbat asterisks
    /// (`✳` at rest, `✢✶✻✽` as frames) across versions; Gemini CLI uses `✦`,
    /// `⏲`, `◇` and `✋`. Wide on purpose: a frame this misses turns a
    /// perfectly good title into "not an agent's", and that failure is silent.
    private static func isMarker(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2722...0x2749, // dingbat stars and asterisks, ✳ among them
             0x25D0...0x25D3, // ◐◑◒◓
             0x2800...0x28FF, // braille spinner frames
             0x23F2, 0x23FA,  // ⏲ ⏺
             0x25C7, 0x25CF, 0x25CB, 0x25C6, // ◇ ● ○ ◆
             0x270B,          // ✋
             0x2022, 0x00B7:  // • ·
            return true
        default:
            return false
        }
    }

    /// Titles that describe the agent rather than the work. Compared
    /// case-insensitively and whole, so "Ready to merge" is still a name.
    private static let stateWords: Set<String> = [
        "working", "ready", "thinking", "idle", "busy", "done",
        "action required", "waiting", "waiting for input",
        "claude", "claude code", "codex", "gemini", "gemini cli", "aider",
    ]

    private static func isState(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if stateWords.contains(lowered) { return true }
        // Codex prefixes "[ ! ] Action Required"; a name that *contains* the
        // phrase is a status line whatever surrounds it.
        return lowered.contains("action required")
    }
}
