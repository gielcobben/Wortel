import Foundation

/// Resume long-lived agent CLIs (Claude Code, …) across an app relaunch.
///
/// The bundled zsh integration writes a marker file named by the surface's
/// `WORTEL_SESSION_ID` into `agents/` when an agent CLI launches (preexec) and
/// removes it at the next shell prompt (precmd) — i.e. when the agent exits.
/// A marker that outlives an app quit therefore means "an agent was still
/// running in this session", which is exactly when we want to resume it.
///
/// On restore, `SessionManager` calls `consumeSnapshot()` to read the leftover
/// markers, then seeds each matching session's `pendingResumeInput` so its
/// first shell auto-runs the agent's resume command. See
/// `Resources/ghostty/shell-integration/zsh/ghostty-integration`.
enum AgentResumeStore {
    /// Shared with the shell integration, which hard-codes the same path.
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wortel/agents", isDirectory: true)

    /// The command that reopens an agent's most recent conversation for the
    /// current directory. `claude --continue` just reattaches to the last
    /// session — it spends nothing until you actually type. Extend as other
    /// agents gain a stable "resume the last conversation" invocation; the shell
    /// records any agent it detects, and unmapped ones are simply left cold.
    static let resumeCommands: [String: String] = [
        "claude": "claude --continue",
    ]

    private static func markerURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString)
    }

    /// Read the previous run's markers as session id -> resume input (command +
    /// newline), then clear the directory: every still-live agent re-registers
    /// on its next preexec, and markers for sessions that no longer exist
    /// shouldn't linger.
    static func consumeSnapshot() -> [UUID: String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [:] }

        var result: [UUID: String] = [:]
        for url in entries {
            defer { try? fm.removeItem(at: url) }
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let name = (try? String(contentsOf: url, encoding: .utf8))?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  let command = resumeCommands[name] else { continue }
            result[id] = command + "\n"
        }
        return result
    }

    /// Drop a session's marker when it's closed, so the killed shell (which
    /// never reaches its prompt to clean up) doesn't leave a stale entry.
    static func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(at: markerURL(for: sessionID))
    }
}
