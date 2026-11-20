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
    /// has anything to read from it. `guessing: false` keeps to what is
    /// exact: the process's own word and a command line that names its
    /// conversation, never a start time or the newest file in the folder.
    static func observe(agent: String, livePID: pid_t?, cwd: String,
                        argv: String?, startedAt: Date?, guessing: Bool = true) -> String? {
        switch agent {
        case "claude":
            // The process file is exact, whatever started it; the command line
            // names the conversation of every resume; the transcript created
            // just after start covers a fresh `claude` with no process file;
            // for --continue, the newest is the one being appended to now.
            if let pid = livePID, let id = AgentResumeStore.claudeConversationID(pid: pid) { return id }
            if let id = AgentResumeStore.claudeResumeTarget(argv: argv) { return id }
            guard guessing else { return nil }
            if let startedAt, let id = AgentResumeStore.claudeConversationID(cwd: cwd, startedAt: startedAt) {
                return id
            }
            guard AgentResumeStore.claudeContinuesLatest(argv: argv) else { return nil }
            return AgentResumeStore.latestClaudeSessionID(cwd: cwd)
        case "pi":
            if let id = Pi.target(argv: argv, cwd: cwd) { return id }
            guard guessing else { return nil }
            if let startedAt, let id = Pi.started(near: startedAt, cwd: cwd) { return id }
            guard Pi.continuesLatest(argv: argv) else { return nil }
            return Pi.latest(cwd: cwd)
        case "codex":
            if let id = Codex.target(argv: argv) { return id }
            guard guessing else { return nil }
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

    /// The last moment there was a sign of a running Pi or Codex being in
    /// conversation `id`: when it started, if its command line names the
    /// conversation, or the last write to the conversation's file, whichever
    /// is later. nil with neither.
    ///
    /// Neither agent says which conversation it is in, and a `/new` or a
    /// `/resume` inside one moves it without a word to anyone. Either takes
    /// keys, so text that went into the session after this moment is text
    /// that may have moved it, and before it, cannot have: the conversation
    /// was still being written to, or had just been asked for by name.
    /// Claude needs none of this. Its process file names its conversation.
    static func lastSeenIn(agent: String, id: String, cwd: String, argv: String?, startedAt: Date,
                           piRoot: URL = Pi.root, codexRoot: URL = Codex.root) -> Date? {
        let named: String?
        let file: URL?
        switch agent {
        case "pi":
            named = Pi.target(argv: argv, cwd: cwd, root: piRoot)
            file = Pi.file(id: id, cwd: cwd, root: piRoot)
        case "codex":
            named = Codex.target(argv: argv)
            file = Codex.file(id: id, root: codexRoot)
        default:
            return nil
        }
        let written = file.flatMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let asked = named?.lowercased() == id.lowercased() ? startedAt : nil
        return [written, asked].compactMap { $0 }.max()
    }

    /// The agent's own words for "resume conversation `id`", after its name,
    /// or nil for an agent without exact resume or an id that can't be typed.
    static func resumeWords(agent: String, id: String) -> [String]? {
        guard AgentCommandLine.isSafeID(id) else { return nil }
        switch agent {
        case "claude": return ["--resume", id]
        case "pi": return ["--session", id]
        case "codex": return ["resume", id]
        default: return nil
        }
    }

    // MARK: - A lost keeper

    /// An agent whose marker went at a prompt, kept a moment in case the
    /// prompt was its shell dying rather than you quitting it.
    ///
    /// When the keeper goes, the pty closes and the shell and agent are both
    /// hung up. Claude exits 0 on SIGHUP, and a shell quick enough to reach
    /// its prompt before its own hangup clears the marker exactly as if you
    /// had typed `/exit`. On 2026-10-10 that was three agents of nine, and
    /// those three were never resumed.
    struct EndedAgent {
        /// Its shell pid is the shell it ran in.
        let marker: AgentMarker
        /// What it was last seen in. See `Session.liveConversationID`.
        let conversationID: String?
        let at: Date
    }

    /// Whether a typed resume has been answered: the agent is running in that
    /// session (the resume started it, or it never stopped and the shell let
    /// the resume be). Until then it is still owed, so a resume typed into a
    /// shell that died before running it (a keeper lost twice, a logout
    /// halfway through) is not forgotten.
    static func confirms(_ marker: AgentMarker, _ owed: OwedResume) -> Bool {
        owed.typedAt != nil && marker.agent == owed.agent.agent
    }

    /// How long after an agent ended, with its shell gone too, a save still
    /// counts it as running. A logout ends the keeper's shells and then quits
    /// the app; the shells clear their markers on the way, so without this the
    /// quit saved no agent to resume.
    static let endedWithShell: TimeInterval = 10

    /// How long before the keeper was lost an agent may have ended and still
    /// count as ended by it. The hangup reaches every shell within moments;
    /// someone quitting an agent this close to a keeper dying is rare, and
    /// costs only a conversation reopened.
    static let endedWithKeeper: TimeInterval = 5

    /// The agent a terminal whose shell went with the keeper is owed back,
    /// and the conversation its own process last named: the one running, else
    /// one that ended as the keeper went. nil when there's none.
    static func lostWithKeeper(running: AgentMarker?, liveConversationID: String?,
                               ended: EndedAgent?, keeperLostAt: Date)
        -> (marker: AgentMarker, conversationID: String?)? {
        if let running { return (running, liveConversationID) }
        guard let ended, ended.at >= keeperLostAt.addingTimeInterval(-endedWithKeeper),
              ended.at <= keeperLostAt.addingTimeInterval(keeperLossSettles)
        else { return nil }
        return (ended.marker, ended.conversationID)
    }

    /// How long after a keeper is lost its shells are taken to be ending
    /// with it. A shell that ends later outlived it, and ends like any other:
    /// you typed `exit`, or quit the agent first. Only one that ends with its
    /// agent still running (no prompt reached) is still brought back.
    static let keeperLossSettles: TimeInterval = 10

    /// Whether a keeper-held terminal whose shell has ended, after its keeper
    /// was lost, gets a new shell rather than ending: it ended as the keeper
    /// went, or it is the session's own terminal and its agent never handed
    /// it back a prompt.
    static func restartsAfterLoss(lostAt: Date, endedAt: Date, isSessionTerminal: Bool,
                                  agentRunning: Bool) -> Bool {
        endedAt <= lostAt.addingTimeInterval(keeperLossSettles) || (isSessionTerminal && agentRunning)
    }

    /// Where an agent whose process is gone picks up again.
    enum ResumePoint: Equatable {
        /// This conversation.
        case conversation(String)
        /// None: it never had one. Started again as it was started.
        case fresh
        /// Nothing says; the agent's own "continue the latest" decides.
        case unknown

        var conversationID: String? {
            if case .conversation(let id) = self { return id }
            return nil
        }
    }

    /// Where to resume an agent once its process is gone, best evidence first:
    ///
    /// 1. `said`: what the process itself said it was in, while it ran (exact,
    ///    and the only thing that follows a `/clear` or `/resume` inside
    ///    Claude, after which the command line names the conversation it
    ///    *started* in). **If that conversation was never written, it never
    ///    had one**: an agent opened and never typed into. It starts afresh.
    ///    Passing over to the next evidence instead is what put such agents
    ///    into another session's conversation: the guess below, and "continue
    ///    the latest", both land on whatever else in the folder was busy
    ///    (2026-11-20: four sessions resumed into one).
    /// 2. `named`: the conversation its command line names.
    /// 3. `guessed`: by its start time, which another session's conversation
    ///    can match.
    /// 4. `last`: the one this session was last seen in.
    ///
    /// Only a conversation that can still be resumed (`exists`) is returned.
    static func resumePoint(said: String?, named: @autoclosure () -> String?,
                            guessed: @autoclosure () -> String?, last: String?,
                            exists: (String) -> Bool) -> ResumePoint {
        if let said { return exists(said) ? .conversation(said) : .fresh }
        if let named = named(), exists(named) { return .conversation(named) }
        if let guessed = guessed(), exists(guessed) { return .conversation(guessed) }
        if let last, exists(last) { return .conversation(last) }
        return .unknown
    }

    /// Whether the agent a session ran ended with its shell rather than at your
    /// hand, as far as a save can tell: it ended moments ago and its shell is
    /// gone too. You quit an agent at its prompt and the shell stays.
    static func endedWithItsShell(_ ended: EndedAgent?, now: Date, shellIsGone: (pid_t) -> Bool) -> Bool {
        guard let ended, now.timeIntervalSince(ended.at) <= endedWithShell,
              let shell = ended.marker.shellPID else { return false }
        return shellIsGone(shell)
    }

    /// Two paths name the same folder. `/tmp` is `/private/tmp`, and the shell's
    /// `$PWD` keeps whichever was typed while the agents record the resolved one.
    static func samePath(_ a: String, _ b: String) -> Bool {
        resolved(a) == resolved(b)
    }

    /// The physical path, as the agents themselves record it (their cwd comes
    /// from `getcwd`). See `AgentResumeStore.physicalPath` for why not
    /// `resolvingSymlinksInPath`.
    static func resolved(_ path: String) -> String {
        AgentResumeStore.physicalPath(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// How far the shell's start time may be from the agent's own: the shell
    /// records it at `preexec`, a second before the agent is up at worst.
    static let startTolerance: TimeInterval = 10

    /// The words of a one-line command, as the marker records it.
    static func words(_ argv: String?) -> [String] {
        AgentCommandLine.words(argv)
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

        /// The file conversation `id` is written to in `cwd`'s folder, for
        /// reading what was last said in it (`AgentAnswer.pi`).
        static func file(id: String, cwd: String, root: URL = root) -> URL? {
            let dir = root.appendingPathComponent(directoryName(cwd: cwd), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.first { url in
                url.pathExtension == "jsonl"
                    && parse(fileName: url.deletingPathExtension().lastPathComponent)?.id == id.lowercased()
            }
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

        /// The rollout conversation `id` is written to, found from the day its
        /// id says it was made, for reading what was last said in it
        /// (`AgentAnswer.codex`).
        static func file(id: String, root: URL = root) -> URL? {
            guard let created = uuidV7Date(id) else { return nil }
            return files(in: dayDirectories(around: created, root: root)).first {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(id.lowercased())
            }
        }

        /// Whether a turn wrote to the rollout at or after `since`, from its
        /// tail (newest last; it may start mid-line).
        ///
        /// A turn opens with `task_started` and the user's message, and every
        /// step of it is a `response_item`.
        ///
        /// Only those count. A rollout also takes lines that belong to no turn
        /// (`thread_settings_applied`, measured three months after its
        /// conversation's last turn), so "anything newer than `since`" would
        /// be wrong the same way the title is.
        static func tookTurn(_ data: Data, since: Date) -> Bool {
            lastTurnWrite(data, since: since) != nil
        }

        /// When a turn last wrote to the rollout, if it did at or after
        /// `since`: its `task_complete`, once the turn is over.
        static func lastTurnWrite(_ data: Data, since: Date) -> Date? {
            for entry in AgentAnswer.entries(data) {
                guard let date = AgentFiles.date(entry["timestamp"]) else { continue }
                // Appended in order, so everything further back is older too.
                if date < since { return nil }
                if isTurnEntry(entry) { return date }
            }
            return nil
        }

        /// What the rollouts say about a quiet that began at `since`.
        enum TurnReading: Equatable {
            /// A turn wrote this tail, which is where its answer is, last at
            /// `lastWrite`.
            case turn(Data, lastWrite: Date)
            /// Nothing a turn writes, anywhere this session could have written.
            case noTurn
            /// The session's own rollout couldn't be read: no verdict.
            case unknown
        }

        /// Whether a turn wrote to conversation `id`'s rollout at or after
        /// `since`, or to another rollout of `cwd` written since then. A
        /// `/new` or `/resume` inside Codex moves the session to another
        /// conversation without a word to the shell, so the id it knows can be
        /// one it has left, or none (`codex` started, then an old conversation
        /// picked). Conversations in `others` belong to other sessions and are
        /// never this one's evidence: two Codex sessions in one folder would
        /// otherwise answer for each other.
        ///
        /// A known `id` whose rollout can't be read is `.unknown`, whatever
        /// the folder holds, so that session keeps the old behaviour. With no
        /// id and nothing written, `.noTurn`: Codex writes its rollout at the
        /// first prompt, so a session that has none has taken no turn.
        ///
        /// Only rollouts modified since `since` are opened, so the fallback
        /// costs a listing and nothing else on the quiet sessions it exists
        /// to silence. Blocking file IO: call off the main thread.
        static func turnReading(conversation id: String?, cwd: String, since: Date,
                                others: Set<String> = [], root: URL = root) -> TurnReading {
            if let id {
                guard let tail = file(id: id, root: root).flatMap(ClaudeTranscriptTail.readTail(of:))
                else { return .unknown }
                if let last = lastTurnWrite(tail, since: since) { return .turn(tail, lastWrite: last) }
            }
            let skip = Set((Array(others) + [id].compactMap { $0 }).map { $0.lowercased() })
            for url in rollouts(modifiedSince: since, root: root) {
                guard let parsed = parse(fileName: url.deletingPathExtension().lastPathComponent),
                      !skip.contains(parsed.id),
                      meta(of: url).map({ AgentConversation.samePath($0.cwd, cwd) }) == true,
                      let tail = ClaudeTranscriptTail.readTail(of: url)
                else { continue }
                if let last = lastTurnWrite(tail, since: since) { return .turn(tail, lastWrite: last) }
            }
            return .noTurn
        }

        /// Every rollout written to at or after `since`, newest first, from
        /// the whole tree: a resumed conversation is appended to in the day
        /// folder it was made in, however old.
        static func rollouts(modifiedSince since: Date, root: URL = root) -> [URL] {
            let key = URLResourceKey.contentModificationDateKey
            guard let walk = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [key], options: [.skipsHiddenFiles])
            else { return [] }
            var found: [(URL, Date)] = []
            for case let url as URL in walk where url.pathExtension == "jsonl" {
                guard let modified = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate,
                      modified >= since else { continue }
                found.append((url, modified))
            }
            return found.sorted { $0.1 > $1.1 }.map(\.0)
        }

        /// A line only a turn writes. Codex persists `task_started`,
        /// `task_complete` and `turn_aborted` for every turn, a review's
        /// included (`rollout/src/policy.rs`); the `turn_` spellings are
        /// accepted aliases, listed so a rename doesn't silence every Codex
        /// turn end. What it also persists and is *not* here is bookkeeping:
        /// `thread_settings_applied`, `thread_goal_updated`,
        /// `thread_rolled_back`, `token_count`, `session_meta`.
        private static func isTurnEntry(_ entry: [String: Any]) -> Bool {
            switch entry["type"] as? String {
            case "response_item", "turn_context", "compacted":
                return true
            case "event_msg":
                let kind = (entry["payload"] as? [String: Any])?["type"] as? String
                return kind.map(turnEvents.contains) ?? false
            default:
                return false
            }
        }

        private static let turnEvents: Set<String> = [
            "task_started", "task_complete", "turn_started", "turn_complete", "turn_aborted",
            "user_message", "agent_message", "agent_reasoning",
            "entered_review_mode", "exited_review_mode", "context_compacted",
            "patch_apply_end", "mcp_tool_call_end", "web_search_end", "image_generation_end",
        ]

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

/// A resume a session owes its agent: what to type, for which agent and
/// conversation, and whether it has been typed yet.
///
/// Owed from the moment it is known (a restore, a lost keeper, a shell gone
/// under a running agent) until the agent is seen running in that session
/// again (`AgentConversation.confirms`), and **not** merely until it is typed.
/// Forgetting it at the typing lost it whenever the typed command never ran:
/// a keeper lost twice in a row, a logout that ended the new shells too, an
/// agent that failed to start.
struct OwedResume {
    let agent: AgentMarker
    let conversationID: String?
    /// The command, ending in a newline when it should run.
    let input: String
    /// When it went into a shell; nil while it waits for one (a session not
    /// shown since launch).
    var typedAt: Date?

    /// How long a typed resume waits for its agent before it is taken as
    /// failed and stops being owed. Long enough for a slow shell start, short
    /// enough that a resume that can never start (an id the agent refuses, a
    /// PATH without it) is not retried at every launch.
    static let answerWithin: TimeInterval = 120

    /// Still owed at `now`: untyped, or typed recently enough to still be
    /// starting.
    func isOwed(at now: Date) -> Bool {
        typedAt.map { now.timeIntervalSince($0) < Self.answerWithin } ?? true
    }
}

extension PersistedSession {
    /// The conversation saved for this session's running agent, if the save
    /// was of the run `marker` records: a crash can leave a marker for a run
    /// that began after the last save, and the saved id is then another
    /// run's. The same run by its start time; a save from before start times
    /// were kept (2026.47 and older) by its agent and command line. With no
    /// marker, the saved run is the only one there is.
    func savedConversation(forRunOf marker: AgentMarker?) -> String? {
        guard let saved = runningConversationID else { return nil }
        guard let marker else { return saved }
        if let savedStart = runningStartedAt, let started = marker.startedAt {
            return abs(savedStart.timeIntervalSince(started)) < 2 ? saved : nil
        }
        return runningAgent == marker.agent && runningArgv == marker.argv ? saved : nil
    }
}
