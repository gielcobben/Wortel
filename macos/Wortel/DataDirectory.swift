import Foundation

/// Where Wortel keeps its state: the session list, what each terminal was
/// told, agent markers, and the keeper's and the CLI's sockets.
/// `~/Library/Application Support/Wortel`, unless `WORTEL_DATA_DIR` names
/// another folder, or this is a Debug build (below).
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
/// **A Debug build keeps to `Wortel Dev` unless this Mac says otherwise.**
/// Someone who clones the repository and builds it has the released app
/// installed, on the usual folder. A Debug build there used to either bring
/// that app forward and quit, or adopt its sessions, and a keeper speaking
/// another protocol was replaced, which ends every shell in it. So a Debug
/// build is isolated by default: `~/Library/Application Support/Wortel Dev`,
/// and the bundle id `com.gielcobben.Wortel.dev` (project.yml), so its
/// UserDefaults are its own as well.
///
/// The maintainer's daily Wortel *is* a Debug build, from whichever worktree
/// was built last, so the way back is per Mac, not per checkout: a file named
/// `debug-builds-share-this-folder` in the usual folder. With it there, a
/// Debug build uses the usual folder, and `scripts/debug-bundle-id.sh` gives
/// it the released app's bundle id at build time. A per-checkout file would be
/// missing from every worktree Wortel makes. An environment variable would be
/// missing from a launch by the Dock or Finder, and the app, its keeper and
/// the `wortel` command must all come to the same answer, which a file they
/// can each look at gives them.
///
/// `WORTEL_DATA_DIR` beats both, always: test copies depend on it.
///
/// Keep the path short: the sockets live in it, and a socket's path has to fit
/// in 104 bytes.
///
/// Compiled into the app, the keeper, the CLI and the tests, so it is
/// Foundation only.
enum DataDirectory {
    static let variable = "WORTEL_DATA_DIR"

    /// The usual folder's name in Application Support, and a Debug build's.
    static let usualName = "Wortel"
    static let debugName = "Wortel Dev"

    /// In the usual folder: Debug builds on this Mac share it. Read by
    /// `scripts/debug-bundle-id.sh` too, under the same name.
    static let shareMarker = "debug-builds-share-this-folder"

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    private static let applicationSupport: String =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path

    /// The folder in use when it is not the usual one, or nil for the usual
    /// one. Read once, and in the app before anything else: the app clears
    /// every `WORTEL_` variable early in launch (see main.swift, which reads
    /// this first and puts it back, so the keeper and every shell get the
    /// folder by name, a Debug build's included).
    ///
    /// Nil is also what "a test copy, or something like one" is read from
    /// (`ChatFolder`, `AgentSkill`): a Debug build on its own folder keeps its
    /// agents' folders inside it and leaves the installed app's skill alone.
    static let custom: String? = {
        #if WORTEL_TESTS
        // The unit tests compile this file themselves (project.yml sets the
        // flag on that target only). What they drive reaches the data folder
        // on its own: `TerminalModeRecorder.shared` loads and saves
        // `terminal-modes.json`, and its `keepOnly` prunes it to the sessions
        // it knows. Pointed at the real folder, a test run rewrote the running
        // Wortel's file with test sessions. So, without an explicit
        // `WORTEL_DATA_DIR`, the tests get a folder of their own per run.
        if ProcessInfo.processInfo.environment[variable]?.isEmpty ?? true {
            return (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("wortel-tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        #endif
        return resolve(
            environment: ProcessInfo.processInfo.environment[variable],
            debugBuild: isDebugBuild,
            applicationSupport: applicationSupport,
            currentDirectory: FileManager.default.currentDirectoryPath,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }()

    /// The decision, apart from the process it is made in.
    static func resolve(environment: String?, debugBuild: Bool, applicationSupport: String,
                        currentDirectory: String, fileExists: (String) -> Bool) -> String? {
        if let value = environment, !value.isEmpty {
            let expanded = (value as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : currentDirectory + "/" + expanded
            return URL(fileURLWithPath: absolute).standardizedFileURL.path
        }
        guard debugBuild else { return nil }
        let usual = (applicationSupport as NSString).appendingPathComponent(usualName)
        if fileExists((usual as NSString).appendingPathComponent(shareMarker)) { return nil }
        return (applicationSupport as NSString).appendingPathComponent(debugName)
    }

    static let url: URL = URL(
        fileURLWithPath: custom ?? (applicationSupport as NSString).appendingPathComponent(usualName),
        isDirectory: true)

    /// A file or socket in the folder.
    static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}
