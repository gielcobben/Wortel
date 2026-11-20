import Foundation
import os

/// What each session's terminal showed when the app quit, for the terminal
/// that takes its place at the next launch.
///
/// A relaunched terminal used to start empty: all it got was what the keeper
/// buffered while the app was gone, and then its program was made to repaint
/// by a change of width. A shell's scrollback was gone, and an agent's screen
/// was whatever it printed again, at whatever width it was told, with what it
/// had printed before laid out as it was then. Now the screen and its
/// scrollback are written to the data folder as the app quits, the way a
/// hibernating terminal's are (`SurfaceView.saveScreenForQuit`), and written
/// back first at the next launch, at the size they were saved at, before the
/// keeper's replay. Nothing is asked of the program: the terminal is as it
/// left it.
///
/// Used only when it can be trusted, otherwise the old way:
/// - the app that saved it is the last one that ran on this data folder, so
///   no other build came and went in between (`InstanceLock.previousOwner`);
/// - the Mac is in the same light or dark as when it was saved, since the
///   colours in it are the theme's at the time;
/// - the keeper kept everything that came meanwhile (its replay does not
///   start with `ReplayBuffer.resync`).
/// Each file is taken once and deleted; whatever is left a minute after
/// launch (a session that did not come back) is deleted too.
enum SavedScreens {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "saved-screens")

    struct Meta: Codable {
        /// The size the terminal was told, in pixels: written back at it.
        var width: UInt32
        var height: UInt32
        var columns: Int
        var rows: Int
        var dark: Bool
        /// The process that saved it.
        var savedBy: Int32
        var savedAt: Date
    }

    static var folder: URL { DataDirectory.file("saved-screens") }

    private static func files(for session: UUID) -> (screen: URL, meta: URL) {
        (folder.appendingPathComponent("\(session.uuidString).vt"),
         folder.appendingPathComponent("\(session.uuidString).json"))
    }

    static func save(_ screen: Data, meta: Meta, for session: UUID) {
        let (screenURL, metaURL) = files(for: session)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (url, data) in [(screenURL, screen), (metaURL, try JSONEncoder().encode(meta))] {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            log.error("could not save the screen of \(session.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: screenURL)
            try? FileManager.default.removeItem(at: metaURL)
        }
    }

    /// The saved screen of a session, if there is one that can be trusted.
    /// Taken: the files are gone after this, used or not.
    static func take(for session: UUID, dark: Bool) -> (screen: Data, meta: Meta)? {
        let (screenURL, metaURL) = files(for: session)
        defer {
            try? FileManager.default.removeItem(at: screenURL)
            try? FileManager.default.removeItem(at: metaURL)
        }
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
              let screen = try? Data(contentsOf: screenURL) else { return nil }
        guard meta.savedBy == InstanceLock.previousOwner else {
            log.notice("\(session.uuidString, privacy: .public): another app ran since its screen was saved; not used")
            return nil
        }
        guard meta.dark == dark else {
            log.notice("\(session.uuidString, privacy: .public): saved in the other appearance; not used")
            return nil
        }
        return (screen, meta)
    }

    /// Whatever was not taken: sessions that did not come back.
    static func clearLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }
}
