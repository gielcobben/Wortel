import Foundation

/// The agent markers of shells about to be ended for an update or a logout,
/// held aside and put back once the shells are gone, so each agent is resumed
/// rather than taken for one the person quit.
///
/// A shell's last prompt removes its agent's marker (the shell integration's
/// `_ghostty_wortel_clear_agent`), and a hung-up agent ends cleanly and gives
/// its shell that prompt. To the next launch, no marker is an agent someone
/// quit, owed nothing: that lost every running agent at the protocol 2 update
/// (2026-11-20). Killing the shells outright so they never reach the prompt
/// was tried first and taken out the same day: a shell killed that way never
/// saves its history (zsh and bash write it as they exit, and macOS's own
/// `/etc/zshrc` appends nothing before that), and its background jobs are
/// never told it went. So shells are hung up as always, and the markers are
/// put back after.
///
/// Used by the keeper ending on a signal (`KeeperServer.stop`) and by the app
/// replacing a keeper (`KeeperConnection.replaceKeeper`), which works for a
/// keeper of an older build as well: nothing here depends on what runs in the
/// shells.
struct AgentMarkerHold {
    /// Where the shell integration writes the markers: `agents/` in the data
    /// folder, one file per session, named by its id (`AgentResumeStore.directory`).
    static var directory: URL { DataDirectory.url.appendingPathComponent("agents", isDirectory: true) }

    private let directory: URL
    private let held: [String: Data]

    /// Every marker there is now, read while the agents still run.
    init(in directory: URL = AgentMarkerHold.directory) {
        self.directory = directory
        var held: [String: Data] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // A marker is named by a session id; the exit log and a marker being
        // written (a dot-file, a moment from its rename) are not markers.
        for name in names where UUID(uuidString: name) != nil {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { held[name] = data }
        }
        self.held = held
    }

    var count: Int { held.count }

    /// Put back each marker that is gone, as it was. Never over one that is
    /// there: a marker written since is newer than this one. Written beside
    /// it as a dot-file and moved into place, so no reader sees half of it,
    /// and the move fails rather than replace a file that appeared meanwhile.
    /// Returns how many were put back.
    @discardableResult
    func restore() -> Int {
        let fm = FileManager.default
        var restored = 0
        for (name, data) in held {
            let target = directory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            let staging = directory.appendingPathComponent(".\(name).held")
            guard (try? data.write(to: staging)) != nil else { continue }
            if (try? fm.moveItem(at: staging, to: target)) != nil {
                restored += 1
            } else {
                try? fm.removeItem(at: staging)
            }
        }
        return restored
    }
}
