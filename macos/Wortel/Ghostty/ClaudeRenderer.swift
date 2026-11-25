import Foundation

/// Claude Code started in a Wortel shell opens in its fullscreen renderer,
/// unless the person chose a renderer themselves or Claude turned fullscreen
/// off on this Mac.
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
/// settings, but Claude reads the variable before almost everything else
/// (read from its 2.1.331 source): before that setting, so set
/// unconditionally it would override a person who chose `/tui classic`; and
/// before its own safety switch, which turns fullscreen off on a Mac where it
/// failed to start several times (`fullscreenAutoDisabled` in its global
/// config) and names this variable as the override. So it is set only when
/// none of these is there: a `tui` in Claude's user settings, that record in
/// its global config, or either of Claude's switches in what Wortel
/// inherited. Only a screen reader still turns fullscreen off ahead of the
/// variable. Project settings (`.claude/settings.json` in a repository) are
/// not looked at: a shell's folder changes after it starts.
enum ClaudeRenderer {
    static let variable = "CLAUDE_CODE_NO_FLICKER"
    /// Claude's other switch, which turns the alternate screen (and so
    /// fullscreen) off.
    static let offSwitch = "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"
    /// The key in Claude's global config that says it turned fullscreen off
    /// on this Mac after failed starts. Any record counts, of any version:
    /// Claude clears it once fullscreen starts cleanly again.
    static let autoDisabledKey = Data(#""fullscreenAutoDisabled""#.utf8)

    /// What to add to a new shell's environment: the variable, or nothing.
    ///
    /// `settings` is Claude's user `settings.json` and `globalConfig` its
    /// `.claude.json`, each nil when there is none. A settings file that
    /// can't be read as JSON says nothing Wortel can trust, so the person is
    /// left with whatever Claude makes of it.
    static func environment(settings: Data?, globalConfig: Data?,
                            inherited: [String: String]) -> [String: String] {
        if inherited[variable] != nil || inherited[offSwitch] != nil { return [:] }
        if let settings {
            guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any]
            else { return [:] }
            if object["tui"] != nil { return [:] }
        }
        // A search, not a parse: the file is hundreds of kilobytes and the
        // key is used for nothing else.
        if let globalConfig, globalConfig.range(of: autoDisabledKey) != nil { return [:] }
        return [variable: "1"]
    }

    /// Claude's own folder: `CLAUDE_CONFIG_DIR` when that is set.
    private static func configDirectory(inherited: [String: String]) -> String? {
        guard let directory = inherited["CLAUDE_CONFIG_DIR"], !directory.isEmpty else { return nil }
        return (directory as NSString).expandingTildeInPath
    }

    /// Claude's user settings file, `~/.claude/settings.json` by default.
    static func settingsURL(inherited: [String: String], home: String = NSHomeDirectory()) -> URL {
        let directory = configDirectory(inherited: inherited) ?? (home as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
    }

    /// Claude's global config, `~/.claude.json` by default.
    static func globalConfigURL(inherited: [String: String], home: String = NSHomeDirectory()) -> URL {
        let directory = configDirectory(inherited: inherited) ?? home
        return URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
    }

    /// For a shell starting now. Looked at each time, so a `/tui` choice made
    /// in one session holds for every shell started after it; read again only
    /// when a file changed, since every terminal made at a relaunch asks.
    static func forNewShell(inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        environment(settings: cache.contents(of: settingsURL(inherited: inherited)),
                    globalConfig: cache.contents(of: globalConfigURL(inherited: inherited)),
                    inherited: inherited)
    }

    private static let cache = FileCache()

    /// A file's contents, read again only when its size or modification date
    /// changed. Main thread only, like every caller.
    private final class FileCache {
        private struct Entry { let stamp: [FileAttributeKey: AnyHashable]; let data: Data? }
        private var entries: [URL: Entry] = [:]

        func contents(of url: URL) -> Data? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                entries[url] = nil
                return nil
            }
            var stamp: [FileAttributeKey: AnyHashable] = [:]
            stamp[.size] = attributes[.size] as? AnyHashable
            stamp[.modificationDate] = attributes[.modificationDate] as? AnyHashable
            if let entry = entries[url], entry.stamp == stamp { return entry.data }
            let data = try? Data(contentsOf: url)
            entries[url] = Entry(stamp: stamp, data: data)
            return data
        }
    }
}
