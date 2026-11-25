import Foundation

/// A folder of its own for an agent session that would otherwise start in the
/// home folder: `~/Wortel/2026-11-19/1`, `~/Wortel/2026-11-19/2`, …
///
/// Claude Code never records its "Do you trust this folder?" answer for the
/// home folder, so an agent there asks again at every start, and Wortel
/// restarting one (deep sleep, a lost keeper) stopped at that question. Any
/// other folder keeps the answer, and a trusted folder covers every folder
/// under it. So agents get their own folders under one parent, and that
/// parent is trusted once: until it is, the new session starts in the parent
/// itself, where Claude asks its own question, and the answer is kept. The
/// Codex app does the same for a thread with no project (`~/Documents/Codex`).
///
/// Never in `~/Documents`, which macOS guards with a permission prompt and
/// iCloud may sync. A folder made here is never removed: an archived session
/// is resumed in it, and Claude files its conversation under its path.
///
/// **Only a folder Wortel made is used** (`isOurs`): someone may already
/// have a `~/Wortel`, or a `~/wortel`, which is the same folder on a Mac's
/// usual disk. Then nothing here touches it, and an agent starts at home as
/// before.
enum ChatFolder {
    /// The parent of every agent's folder. A copy on a data folder of its own
    /// (`WORTEL_DATA_DIR`, or a Debug build's `Wortel Dev`) keeps its own,
    /// inside that folder.
    static let root: String = DataDirectory.custom.map { $0 + "/chats" }
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("Wortel")

    /// Whether a new agent session headed for `directory` gets a folder of its
    /// own instead: the home folder (nil is home, by `wortel.conf`), or the
    /// parent and anything in it, so ⌘N beside an agent's folder makes a new
    /// one rather than sharing it.
    static func wantsOwnFolder(_ directory: String?, home: String = NSHomeDirectory(),
                               root: String = root) -> Bool {
        guard let directory else { return true }
        let path = standard(directory)
        if path == standard(home) { return true }
        return FolderRoot.root(standard(root), contains: path) && isOurs(root)
    }

    /// The file that says `root` is Wortel's.
    static let markerName = ".made-by-wortel"

    /// Whether `root` is Wortel's to use: it has the marker, or it doesn't
    /// exist yet. A folder made by the first build of this, before the
    /// marker, is recognised by holding nothing but what Wortel puts there
    /// (day folders and the guide), and is marked then.
    static func isOurs(_ root: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        if fm.fileExists(atPath: (root as NSString).appendingPathComponent(markerName)) { return true }
        guard let entries = try? fm.contentsOfDirectory(atPath: root),
              entries.allSatisfy({ isDayName($0) || $0 == "CLAUDE.md" || $0 == ".DS_Store" }),
              (try? String(contentsOfFile: (root as NSString).appendingPathComponent("CLAUDE.md"),
                           encoding: .utf8)).map({ $0 == guide }) ?? true
        else { return false }
        mark(root)
        return true
    }

    private static func mark(_ root: String) {
        let text = "Wortel made this folder for agent sessions with no project of their own.\n"
        try? text.write(toFile: (root as NSString).appendingPathComponent(markerName),
                        atomically: true, encoding: .utf8)
    }

    /// `2026-11-19`, as `dayName` writes them.
    static func isDayName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// The folder to start an agent session in, made on disk, or nil when it
    /// could not be made (the session then starts where it would have).
    /// `command` is the line Settings types: only Claude's trust is read,
    /// and only Claude is started in the parent until it is trusted.
    ///
    /// `rootInUse`: a session already started in the parent and may still be
    /// at the question. Only that one asks there; another made meanwhile goes
    /// to a folder of its own (and is asked there), so two conversations
    /// never share a folder.
    static func make(for command: String, root: String = root, now: Date = Date(), rootInUse: Bool = false,
                     claudeConfig: () -> Data? = readClaudeConfig) -> String? {
        let fm = FileManager.default
        guard isOurs(root) else { return nil }
        let isNew = !fm.fileExists(atPath: root)
        guard (try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        if isNew { mark(root) }
        writeGuide(in: root)
        if isClaude(command), !rootInUse, !trusted(root, claudeConfig: claudeConfig) { return root }
        return nextFolder(in: root, now: now)
    }

    /// Claude's trust in `root`, remembered once it is given: it is never
    /// taken back, and `~/.claude.json` can be megabytes, read on the main
    /// thread as a session is made.
    private static func trusted(_ root: String, claudeConfig: () -> Data?) -> Bool {
        if trustMemo.contains(root) { return true }
        guard claudeTrusts(root, config: claudeConfig()) else { return false }
        trustMemo.insert(root)
        return true
    }

    private static let trustMemo = TrustMemo()

    private final class TrustMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: Set<String> = []
        func contains(_ root: String) -> Bool { lock.withLock { roots.contains(root) } }
        func insert(_ root: String) { _ = lock.withLock { roots.insert(root) } }
    }

    /// The next free `<day>/<n>` under `root`, made: one more than the highest
    /// number already there, so a folder removed by hand is not reused.
    static func nextFolder(in root: String, now: Date = Date()) -> String? {
        let fm = FileManager.default
        let day = (root as NSString).appendingPathComponent(dayName(now))
        guard (try? fm.createDirectory(atPath: day, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let taken = ((try? fm.contentsOfDirectory(atPath: day)) ?? []).compactMap(Int.init)
        var n = (taken.max() ?? 0) + 1
        // `mkdir` and not `createDirectory(withIntermediateDirectories: true)`,
        // which succeeds on a folder that is already there: two sessions made
        // in the same instant must not share one.
        for _ in 0..<100 {
            let path = (day as NSString).appendingPathComponent(String(n))
            if mkdir(path, 0o755) == 0 { return path }
            guard errno == EEXIST else { return nil }
            n += 1
        }
        return nil
    }

    /// What every agent started under `root` reads: Claude Code loads the
    /// `CLAUDE.md` of each folder above where it starts (read when it starts,
    /// so an agent already running sees it after its next resume). It says how to move
    /// the session when the work turns to a project elsewhere (`wortel cd`),
    /// and to ask first. Written when missing, never over one that is there:
    /// once written it is the person's to change.
    static let guide = """
        # Wortel

        This folder was made by Wortel, the terminal this session runs in, as a \
        place for this conversation to start. It is not a project.

        When the work turns to a project somewhere else on this Mac (a \
        repository, an app, a site), offer to move this session there. Once \
        the person agrees, run `wortel cd <that folder>` and finish your \
        reply. When your turn ends, Wortel quits you and continues this same \
        conversation in that folder, so the person sees its git and you get \
        its own settings. Start nothing else after running it: anything still \
        running when you quit stops.

        """

    static func writeGuide(in root: String) {
        guard isOurs(root) else { return }
        let path = (root as NSString).appendingPathComponent("CLAUDE.md")
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? guide.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `2026-11-19`, in the Mac's own time zone.
    static func dayName(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Whether the command starts Claude Code: any of its words, by name, so
    /// `env FOO=1 claude` and a wrapper's `devx claude` count.
    static func isClaude(_ command: String) -> Bool {
        AgentCommandLine.words(command).contains { ($0 as NSString).lastPathComponent == "claude" }
    }

    /// What a new agent session is called before the agent names it:
    /// "Claude", or the command's own name. The folder's name, "1", says
    /// nothing.
    static func sessionName(for command: String) -> String {
        if isClaude(command) { return "Claude" }
        let first = AgentCommandLine.words(command).first { !$0.contains("=") }
            .map { ($0 as NSString).lastPathComponent }
        guard let first, !first.isEmpty else { return "Agent" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Whether Claude Code skips its trust question in `path`: the folder or
    /// one above it is recorded as trusted (`projects[<path>]
    /// .hasTrustDialogAccepted` in `~/.claude.json`), which is how Claude
    /// itself looks outside a git repository (read in 2.1.328, and seen in
    /// this Mac's config: twenty folders under one trusted folder, none with
    /// a record of their own). Read only, never written. Unreadable counts as
    /// not trusted, which costs one question in the parent, not a folder.
    static func claudeTrusts(_ path: String, config: Data?) -> Bool {
        guard let config,
              let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let projects = object["projects"] as? [String: Any] else { return false }
        return PathWalk.upward(from: standard(path)).contains { folder in
            (projects[folder] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
        }
    }

    static func readClaudeConfig() -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return try? Data(contentsOf: home.appendingPathComponent(".claude.json"))
    }

    private static func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
