import Foundation

/// Which conversation an agent is in, for the agents that can resume an exact
/// one: Claude, Pi and Codex.
///
/// Every other agent resumes "the latest conversation in this folder"
/// (`AgentResumeStore.resumeCommands`), which is right until two sessions run
/// the same agent in one folder, and then both come back in the same
/// conversation. These three can be pointed at a specific one, so Wortel
/// learns which, while the agent is running, and asks for that one by id.
///
/// All of it is observation: reading the files each agent already writes,
/// never configuring the agent or writing into its folders. Each agent has its
/// own layout, verified against the agent on 2026-10-07:
///
/// - **Claude**: `~/.claude/projects/<cwd, non-alphanumerics as ->/<id>.jsonl`,
///   plus `~/.claude/sessions/<pid>.json` for each live process (not always
///   written). Resume: `claude --resume <id>`.
/// - **Pi**: `~/.pi/agent/sessions/--<cwd, / and : as ->--/<start>_<id>.jsonl`,
///   where `<start>` is when Pi started (ISO 8601, `:` and `.` as `-`).
///   Resume: `pi --session <id>`.
/// - **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-<local start>-<id>.jsonl`,
///   whose first line is `session_meta` with the id, the cwd and the start.
///   Resume: `codex resume <id>`.
///
/// Pi and Codex write nothing until the first message and keep no file open,
/// so a running one is identified by its command line, else by matching the
/// start time the shell integration recorded against the start time in each
/// conversation's header. Neither has an equivalent of Claude's per-process
/// file.
enum AgentConversation {
    /// The agents this knows how to resume exactly.
    static let exact: Set<String> = ["claude", "pi", "codex"]

    /// The conversation a running agent is in, best evidence first. nil when
    /// nothing says, which leaves the caller with what it already knew.
    ///
    /// `livePID` is the agent's process when it could be found; only Claude
    /// has anything to read from it.
    static func observe(agent: String, livePID: pid_t?, cwd: String,
                        argv: String?, startedAt: Date?) -> String? {
        switch agent {
        case "claude":
            // The process file is exact, whatever started it; the command line
            // names the conversation of every resume; the transcript created
            // just after start covers a fresh `claude` with no process file;
            // for --continue, the newest is the one being appended to now.
            if let pid = livePID, let id = AgentResumeStore.claudeConversationID(pid: pid) { return id }
            if let id = AgentResumeStore.claudeResumeTarget(argv: argv) { return id }
            if let startedAt, let id = AgentResumeStore.claudeConversationID(cwd: cwd, startedAt: startedAt) {
                return id
            }
            guard AgentResumeStore.claudeContinuesLatest(argv: argv) else { return nil }
            return AgentResumeStore.latestClaudeSessionID(cwd: cwd)
        case "pi":
            if let id = Pi.target(argv: argv, cwd: cwd) { return id }
            if let startedAt, let id = Pi.started(near: startedAt, cwd: cwd) { return id }
            guard Pi.continuesLatest(argv: argv) else { return nil }
            return Pi.latest(cwd: cwd)
        case "codex":
            if let id = Codex.target(argv: argv) { return id }
            if let startedAt, let id = Codex.started(near: startedAt, cwd: cwd) { return id }
            guard Codex.resumesLatest(argv: argv) else { return nil }
            return Codex.latest(cwd: cwd)
        default:
            return nil
        }
    }

    /// Whether `id` is one of `agent`'s conversations in `cwd`. A remembered
    /// id is only offered back where it can be resumed: each agent resumes a
    /// conversation from the folder it was held in, and an id remembered for
    /// another agent is no id at all.
    static func exists(agent: String, id: String, cwd: String) -> Bool {
        switch agent {
        case "claude": return AgentResumeStore.claudeTranscriptExists(id: id, cwd: cwd)
        case "pi": return Pi.conversations(cwd: cwd).contains { $0.id == id }
        case "codex": return Codex.exists(id: id, cwd: cwd)
        default: return false
        }
    }

    /// The command that resumes conversation `id` of `agent`, or nil for an
    /// agent without exact resume.
    static func resumeCommand(agent: String, id: String) -> String? {
        switch agent {
        case "claude": return "claude --resume \(id)"
        case "pi": return "pi --session \(id)"
        case "codex": return "codex resume \(id)"
        default: return nil
        }
    }

    /// Two paths name the same folder. `/tmp` is `/private/tmp`, and the shell's
    /// `$PWD` keeps whichever was typed while the agents record the resolved one.
    static func samePath(_ a: String, _ b: String) -> Bool {
        resolved(a) == resolved(b)
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// How far the shell's start time may be from the agent's own: the shell
    /// records it at `preexec`, a second before the agent is up at worst.
    static let startTolerance: TimeInterval = 10

    /// The words of a one-line command, as the marker records it.
    static func words(_ argv: String?) -> [String] {
        argv?.split(separator: " ").map(String.init) ?? []
    }

    // MARK: - Pi

    enum Pi {
        static var root: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        }

        /// Pi's own name for a folder's session directory (`session-manager.js`,
        /// `getDefaultSessionDirPath`): the resolved path without its leading
        /// slash, `/`, `\` and `:` as `-`, between `--` and `--`.
        static func directoryName(cwd: String) -> String {
            var path = AgentConversation.resolved(cwd)
            if path.hasPrefix("/") { path.removeFirst() }
            let safe = path.map { "/\\:".contains($0) ? "-" : String($0) }.joined()
            return "--\(safe)--"
        }

        /// A folder's conversations: id and start, from the file names alone.
        static func conversations(cwd: String, root: URL = root)
            -> [(id: String, started: Date, modified: Date)] {
            let dir = root.appendingPathComponent(directoryName(cwd: cwd), isDirectory: true)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return [] }
            return files.compactMap { url in
                guard url.pathExtension == "jsonl",
                      let parsed = parse(fileName: url.deletingPathExtension().lastPathComponent)
                else { return nil }
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?
                    .contentModificationDate ?? parsed.started
                return (parsed.id, parsed.started, modified)
            }
        }

        /// `2026-09-09T02-18-28-028Z_01a083f5-a13c-7b70-b215-1593799518d0` →
        /// the id and when Pi started.
        static func parse(fileName: String) -> (id: String, started: Date)? {
            guard let split = fileName.firstIndex(of: "_") else { return nil }
            let stamp = String(fileName[..<split])
            let id = String(fileName[fileName.index(after: split)...]).lowercased()
            guard UUID(uuidString: id) != nil else { return nil }
            // Pi writes toISOString() with ":" and "." made "-":
            // 2026-09-09T02-18-28-028Z → 2026-09-09T02:18:28.028Z.
            let parts = stamp.split(separator: "T", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let time = parts[1].split(separator: "-")
            guard time.count == 4 else { return nil }
            let iso = "\(parts[0])T\(time[0]):\(time[1]):\(time[2]).\(time[3])"
            guard let started = isoFractional.date(from: iso) else { return nil }
            return (id, started)
        }

        /// `--session <id|path>`, `--session=<…>` or `--session-id <id>`. A
        /// path is read for the id in its file name; a partial id is resolved
        /// against the folder's conversations, and only if it is unambiguous.
        static func target(argv: String?, cwd: String, root: URL = root) -> String? {
            let words = AgentConversation.words(argv)
            for (index, word) in words.enumerated() {
                var value: String?
                if word.hasPrefix("--session=") {
                    value = String(word.dropFirst("--session=".count))
                } else if word == "--session" || word == "--session-id", index + 1 < words.count {
                    value = words[index + 1]
                }
                guard var value else { continue }
                value = (value as NSString).lastPathComponent
                if value.hasSuffix(".jsonl"), let parsed = parse(fileName: String(value.dropLast(6))) {
                    return parsed.id
                }
                if UUID(uuidString: value) != nil { return value.lowercased() }
                let matches = conversations(cwd: cwd, root: root).filter { $0.id.hasPrefix(value.lowercased()) }
                return matches.count == 1 ? matches[0].id : nil
            }
            return nil
        }

        /// The conversation Pi started at `date`, give or take the tolerance.
        static func started(near date: Date, cwd: String, root: URL = root) -> String? {
            conversations(cwd: cwd, root: root)
                .filter { abs($0.started.timeIntervalSince(date)) <= AgentConversation.startTolerance }
                .min { abs($0.started.timeIntervalSince(date)) < abs($1.started.timeIntervalSince(date)) }?
                .id
        }

        static func continuesLatest(argv: String?) -> Bool {
            AgentConversation.words(argv).contains { $0 == "-c" || $0 == "--continue" }
        }

        static func latest(cwd: String) -> String? {
            conversations(cwd: cwd).max { $0.modified < $1.modified }?.id
        }
    }

    // MARK: - Codex

    enum Codex {
        static var root: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        }

        /// The conversation a command line names: `codex resume <id>` (also
        /// under `exec`). `--last` names none.
        static func target(argv: String?) -> String? {
            let words = AgentConversation.words(argv)
            guard let resume = words.firstIndex(of: "resume") else { return nil }
            return words[(resume + 1)...].first { UUID(uuidString: $0) != nil }?.lowercased()
        }

        static func resumesLatest(argv: String?) -> Bool {
            let words = AgentConversation.words(argv)
            return words.contains("resume") && words.contains("--last")
        }

        /// The day folders a conversation started around `date` can be in:
        /// that local day and either side, since a start near midnight and the
        /// shell's clock can straddle one.
        static func dayDirectories(around date: Date, root: URL) -> [URL] {
            let calendar = Calendar.current
            return [-1, 0, 1].compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                guard let y = c.year, let m = c.month, let d = c.day else { return nil }
                return root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d), isDirectory: true)
            }
        }

        /// `rollout-2026-06-29T08-34-45-019f135f-fada-7d42-a92f-5d96b6fc16f8` →
        /// the id and the local start time in the name.
        static func parse(fileName: String) -> (id: String, started: Date)? {
            guard fileName.hasPrefix("rollout-") else { return nil }
            let rest = fileName.dropFirst("rollout-".count)
            // 19 characters of local time, a dash, then the id.
            guard rest.count > 20 else { return nil }
            let stamp = String(rest.prefix(19))
            let id = String(rest.dropFirst(20)).lowercased()
            guard UUID(uuidString: id) != nil else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            guard let started = formatter.date(from: stamp) else { return nil }
            return (id, started)
        }

        /// The id and cwd from a rollout's first line, `session_meta`. Read in
        /// a bounded chunk: the line carries the base instructions and runs to
        /// tens of kilobytes.
        static func meta(of url: URL) -> (id: String, cwd: String)? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
            let line = data.split(separator: 0x0A, maxSplits: 1).first ?? data[...]
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String, let cwd = payload["cwd"] as? String
            else { return nil }
            return (id.lowercased(), cwd)
        }

        static func files(in directories: [URL]) -> [URL] {
            directories.flatMap { dir in
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            }.filter { $0.pathExtension == "jsonl" }
        }

        /// The conversation Codex started at `date` in `cwd`.
        static func started(near date: Date, cwd: String, root: URL = root) -> String? {
            let candidates = files(in: dayDirectories(around: date, root: root)).compactMap { url -> (URL, String, TimeInterval)? in
                guard let parsed = parse(fileName: url.deletingPathExtension().lastPathComponent) else { return nil }
                let distance = abs(parsed.started.timeIntervalSince(date))
                // File names are whole seconds; allow the same tolerance.
                guard distance <= AgentConversation.startTolerance + 1 else { return nil }
                return (url, parsed.id, distance)
            }.sorted { $0.2 < $1.2 }
            return candidates.first { candidate in
                meta(of: candidate.0).map { AgentConversation.samePath($0.cwd, cwd) } ?? false
            }?.1
        }

        /// The newest conversation in `cwd` from the last week: what
        /// `codex resume --last` continues while it is running.
        static func latest(cwd: String, now: Date = Date(), root: URL = root) -> String? {
            let days = (0..<7).flatMap { back -> [URL] in
                guard let day = Calendar.current.date(byAdding: .day, value: -back, to: now) else { return [] }
                return [dayDirectories(around: day, root: root)[1]]
            }
            let newestFirst = files(in: days).sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (a ?? .distantPast) > (b ?? .distantPast)
            }
            for url in newestFirst.prefix(50) {
                if let meta = meta(of: url), AgentConversation.samePath(meta.cwd, cwd) { return meta.id }
            }
            return nil
        }

        /// Whether `id` is a Codex conversation held in `cwd`. Codex ids are
        /// UUIDv7, whose first 48 bits are the creation time in milliseconds,
        /// so the day folder is known without walking the whole tree.
        static func exists(id: String, cwd: String, root: URL = root) -> Bool {
            guard let created = uuidV7Date(id) else { return false }
            return files(in: dayDirectories(around: created, root: root)).contains { url in
                url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(id.lowercased())
                    && (meta(of: url).map { AgentConversation.samePath($0.cwd, cwd) } ?? false)
            }
        }

        static func uuidV7Date(_ id: String) -> Date? {
            let hex = id.replacingOccurrences(of: "-", with: "")
            guard hex.count == 32, Array(hex)[12] == "7",
                  let millis = UInt64(hex.prefix(12), radix: 16) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
