import CryptoKit
import Foundation

/// The Claude Code skill that tells an agent running in Wortel what the
/// `wortel` command can do (`Resources/wortel-skill.md`), installed in
/// `~/.claude/skills/wortel/SKILL.md`.
///
/// A skill rather than a page in CLAUDE.md: only its one-line description is
/// in every conversation, and the rest is read when it is needed.
///
/// A Mac app has no install step, so it goes in at launch: once, when Claude
/// Code is on the Mac (`~/.claude` exists), and again with each update for as
/// long as the file is exactly what Wortel last wrote. Edited, it is the
/// person's and is left alone. Deleted after Wortel wrote it, it stays
/// deleted. A copy on a data folder of its own (`WORTEL_DATA_DIR`, or a Debug
/// build's `Wortel Dev`) never writes it: the installed app's is left alone.
enum AgentSkill {
    enum Action: Equatable {
        case install
        case update
        /// Already what Wortel ships, but not recorded as written by it
        /// (`~/.claude` synced from another Mac, defaults reset): recorded
        /// now, so the next update still reaches it.
        case adopt
        case leave
    }

    /// What to do, from what is on disk and what Wortel last wrote there.
    /// `written` is the digest of the last file Wortel wrote, nil if it never
    /// has.
    static func decide(claudeInstalled: Bool, onDisk: Data?, bundled: Data, written: String?) -> Action {
        guard claudeInstalled else { return .leave }
        guard let onDisk else { return written == nil ? .install : .leave }
        if onDisk == bundled { return written == digest(bundled) ? .leave : .adopt }
        // Untouched since Wortel wrote it: Wortel's to bring up to date.
        return digest(onDisk) == written ? .update : .leave
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let writtenKey = "agentSkill.writtenDigest"

    /// Install or update the skill if it is Wortel's to. Off the main thread:
    /// a few small file reads at launch.
    static func sync(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     defaults: UserDefaults = .standard) {
        guard DataDirectory.custom == nil,
              let url = Bundle.main.url(forResource: "wortel-skill", withExtension: "md"),
              let bundled = try? Data(contentsOf: url) else { return }
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let folder = claude.appendingPathComponent("skills/wortel", isDirectory: true)
        let file = folder.appendingPathComponent("SKILL.md")
        var isDirectory: ObjCBool = false
        let installed = FileManager.default.fileExists(atPath: claude.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let action = decide(claudeInstalled: installed, onDisk: try? Data(contentsOf: file),
                            bundled: bundled, written: defaults.string(forKey: writtenKey))
        switch action {
        case .leave: return
        case .adopt:
            defaults.set(digest(bundled), forKey: writtenKey)
            return
        case .install, .update: break
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bundled.write(to: file, options: .atomic)
            defaults.set(digest(bundled), forKey: writtenKey)
        } catch {
            NSLog("wortel: couldn't write the Claude Code skill: %@", error.localizedDescription)
        }
    }
}
