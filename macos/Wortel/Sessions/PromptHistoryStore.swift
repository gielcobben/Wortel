import Foundation

/// Reads what the agents keep of the prompts typed to them, for ⌘Y.
///
/// The disk half of `PromptHistory`, and its whole job is to stay cheap,
/// because it runs while the terminal beside it is in use (Wortel's one
/// rule: cost follows what's on screen, not the size of what's on disk):
///
/// - **Only when asked.** Nothing is read until the panel opens, and nothing
///   is watched. `load()` blocks, so it is only ever called off the main
///   thread (`PromptHistoryModel`).
/// - **Bounded.** A history file is read from its end, `tailBytes` at most;
///   Pi, which keeps one file per conversation, has its newest
///   `piFileLimit` read, `piTailBytes` each and `piTotalBytes` in all; the
///   result is cut at `entryLimit`. Claude's history file is a few MB after a
///   year of daily use, so the tail is most of it, and the newest prompts are
///   the ones looked for.
/// - **Nothing written.** No index, no cache on disk (see `PromptHistory` on
///   why). What is kept, in memory, is each file's parse, keyed by its size
///   and modification date, so opening the panel a second time reads only
///   what changed.
final class PromptHistoryStore: @unchecked Sendable {
    static let shared = PromptHistoryStore()

    static let tailBytes = 4 << 20
    static let piFileLimit = 300
    static let piTailBytes = 1 << 20
    static let piTotalBytes = 16 << 20
    static let entryLimit = 5000
    /// Codex conversations whose directory is looked up per load. Each is a
    /// directory listing and one line read; the rest go without a project.
    static let codexLookupLimit = 200
    /// A paste from Claude's cache bigger than this stays its placeholder.
    static let pasteBytes = 256 << 10

    /// Where each agent keeps its files, as each agent resolves it: its
    /// variable if Wortel was started with one, else the default under home.
    /// Wortel itself is started by launchd and sees no shell's exports, so
    /// in practice this is the default unless the variable is set for the
    /// user's whole login session (`launchctl setenv`).
    struct Locations: Sendable {
        var claude: URL
        var codex: URL
        /// Pi's sessions folder, not its agent folder.
        var piSessions: URL

        static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Locations {
            func folder(_ variable: String, _ fallback: String) -> URL {
                if let value = environment[variable], !value.isEmpty {
                    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
                }
                return home.appendingPathComponent(fallback, isDirectory: true)
            }
            return Locations(claude: folder("CLAUDE_CONFIG_DIR", ".claude"),
                             codex: folder("CODEX_HOME", ".codex"),
                             piSessions: folder("PI_CODING_AGENT_DIR", ".pi/agent")
                                .appendingPathComponent("sessions", isDirectory: true))
        }
    }

    private struct Parsed {
        let size: UInt64
        let modified: Date
        let entries: [PromptHistory.Entry]
    }

    private let lock = NSLock()
    private var parsed: [String: Parsed] = [:]
    /// Directory → project (`PromptHistory.Entry.project`). A directory's
    /// repository doesn't change while the app runs, and asking is a walk up
    /// the tree with a `stat` per level.
    private var projects: [String: String] = [:]
    /// Codex conversation → its directory, nil once looked for and not found.
    private var codexDirectories: [String: String?] = [:]

    /// Every prompt, newest first, each once, with its project. Blocking.
    func load(from locations: Locations = .current()) -> [PromptHistory.Entry] {
        var lists: [[PromptHistory.Entry]] = []
        let claude = locations.claude
        lists.append(entries(of: claude.appendingPathComponent("history.jsonl"), maxBytes: Self.tailBytes) { line in
            PromptHistory.claudeEntry(line) { hash in Self.cachedPaste(hash, in: claude) }
        })
        lists.append(codexEntries(in: locations.codex))
        lists.append(piEntries(in: locations.piSessions))
        var merged = PromptHistory.merged(lists, limit: Self.entryLimit)
        for index in merged.indices {
            merged[index].project = merged[index].directory.map(project(of:))
        }
        return merged
    }

    /// The project `directory` belongs to, as `Entry.project` names it.
    func project(of directory: String) -> String {
        lock.lock()
        if let known = projects[directory] { lock.unlock(); return known }
        lock.unlock()
        let standard = (directory as NSString).standardizingPath
        let project = GitWorktree.repositoryHome(containing: standard) ?? standard
        lock.lock()
        projects[directory] = project
        lock.unlock()
        return project
    }

    // MARK: - Files

    /// A JSONL file's entries, from the last `maxBytes` of it, reusing the
    /// last parse when the file hasn't changed.
    private func entries(of url: URL, maxBytes: Int,
                         parse: (Data) -> PromptHistory.Entry?) -> [PromptHistory.Entry] {
        guard let stamp = Self.stamp(of: url) else { return [] }
        lock.lock()
        if let cached = parsed[url.path], cached.size == stamp.size, cached.modified == stamp.modified {
            lock.unlock()
            return cached.entries
        }
        lock.unlock()
        guard let tail = Self.tail(of: url, maxBytes: maxBytes) else { return [] }
        let entries = PromptHistory.lines(in: tail.data, fromMiddle: tail.fromMiddle).compactMap(parse)
        lock.lock()
        parsed[url.path] = Parsed(size: stamp.size, modified: stamp.modified, entries: entries)
        lock.unlock()
        return entries
    }

    static func stamp(of url: URL) -> (size: UInt64, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (size, modified)
    }

    /// The last `maxBytes` of a file, and whether that started mid-file.
    static func tail(of url: URL, maxBytes: Int) -> (data: Data, fromMiddle: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    /// A file's first line, if it ends within `maxBytes`.
    static func firstLine(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        guard let newline = data.firstIndex(of: 0x0A) else { return data.count < maxBytes ? data : nil }
        return data[data.startIndex..<newline]
    }

    /// A paste Claude kept out of its history file, by hash.
    private static func cachedPaste(_ hash: String, in claude: URL) -> String? {
        guard hash.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let url = claude.appendingPathComponent("paste-cache/\(hash).txt")
        guard let stamp = stamp(of: url), stamp.size <= UInt64(pasteBytes),
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Codex

    private func codexEntries(in codex: URL) -> [PromptHistory.Entry] {
        var entries = self.entries(of: codex.appendingPathComponent("history.jsonl"), maxBytes: Self.tailBytes,
                                   parse: PromptHistory.codexEntry)
        var lookedUp = 0
        // Newest first, so the lookups are spent on what's shown first.
        for index in entries.indices.reversed() {
            guard let id = entries[index].conversation else { continue }
            lock.lock()
            let known = codexDirectories[id]
            lock.unlock()
            if let known {
                entries[index].directory = known
                continue
            }
            guard lookedUp < Self.codexLookupLimit else { continue }
            lookedUp += 1
            let directory = Self.codexDirectory(of: id, around: entries[index].date, in: codex)
            lock.lock()
            codexDirectories[id] = .some(directory)
            lock.unlock()
            entries[index].directory = directory
        }
        return entries
    }

    /// Where a Codex conversation ran, from its rollout's first line. The
    /// rollout is filed under the local date it started, which is the day of
    /// its first prompt or, for one that ran past midnight, a day either side.
    static func codexDirectory(of id: String, around date: Date, in codex: URL,
                               calendar: Calendar = .current) -> String? {
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        let suffix = "-\(id).jsonl"
        for offset in [0, -1, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let folder = sessions.appendingPathComponent(
                String(format: "%04d/%02d/%02d", year, month, dayOfMonth), isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  let name = names.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(suffix) }),
                  let header = firstLine(of: folder.appendingPathComponent(name), maxBytes: 1 << 20)
            else { continue }
            return PromptHistory.codexDirectory(fromRolloutHeader: header)
        }
        return nil
    }

    // MARK: - Pi

    private func piEntries(in sessions: URL) -> [PromptHistory.Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, modified: Date)] = []
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for url in names where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        var budget = Self.piTotalBytes
        var entries: [PromptHistory.Entry] = []
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(Self.piFileLimit) {
            guard budget > 0, let stamp = Self.stamp(of: file.url) else { break }
            budget -= Int(min(stamp.size, UInt64(Self.piTailBytes)))
            // The header is the first line, which a tail of a long
            // conversation doesn't reach; it's small, read on its own, and
            // only when the file is parsed rather than taken from memory.
            var directory: String??
            entries += self.entries(of: file.url, maxBytes: Self.piTailBytes) { line in
                if directory == nil {
                    directory = .some(Self.firstLine(of: file.url, maxBytes: 64 << 10)
                        .flatMap(PromptHistory.piDirectory))
                }
                return PromptHistory.piEntry(line, directory: directory ?? nil)
            }
        }
        return entries
    }
}
