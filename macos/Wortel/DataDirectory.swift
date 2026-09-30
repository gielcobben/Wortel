import Foundation

/// Where Wortel keeps its state: the session list, what each terminal was
/// told, agent markers, and the keeper's and the CLI's sockets.
/// `~/Library/Application Support/Wortel`, unless `WORTEL_DATA_DIR` names
/// another folder.
///
/// **The override is how a second Wortel runs safely.** Only one Wortel may own
/// a data folder at a time (`InstanceLock`). A build from a worktree, run to
/// try a change, takes a folder of its own instead:
///
///     open --env WORTEL_DATA_DIR=/tmp/wortel-try path/to/Wortel.app
///
/// and gets its own sessions, keeper and `wortel` socket, and never touches
/// yours. The app hands the variable on to the keeper and every shell
/// (main.swift), so everything started from it agrees on the folder, the shell
/// integration included.
///
/// Keep the path short: the sockets live in it, and a socket's path has to fit
/// in 104 bytes.
///
/// Compiled into the app, the keeper, the CLI and the tests, so it is
/// Foundation only.
enum DataDirectory {
    static let variable = "WORTEL_DATA_DIR"

    /// The folder `WORTEL_DATA_DIR` names, made absolute, or nil for the usual
    /// one. Read once, and in the app before anything else: the app clears
    /// every `WORTEL_` variable early in launch (see main.swift, which reads
    /// this first and puts it back).
    static let custom: String? = {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
            return nil
        }
        let expanded = (value as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }()

    static let url: URL = custom.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wortel", isDirectory: true)

    /// A file or socket in the folder.
    static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}
