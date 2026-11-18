import CryptoKit
import Foundation

// ==========================================================================
// EVERY EVENT WORTEL CAN SEND, AND EVERY PROPERTY IT CAN CARRY.
//
// Read this file to answer "could Wortel leak X". Nothing reaches the network
// that is not one of the cases below, and that is enforced by the type system
// rather than by care: every associated value is an enum, a Bool or a bucket,
// and there is no case anywhere that takes a String. A caller *cannot* pass a
// session name, a branch, a path or a line of terminal output, because there is
// no parameter that would accept one.
//
// THINGS THAT MUST NEVER BE SENT, written down because the next person adding
// an event will be tempted by at least one of them:
//
//   session names          repository names        branch names
//   directory paths        file names              command text
//   terminal output        window titles           hostnames
//   usernames              email addresses         anything free-form
//
// An event does carry the moment it happened, because an event without one is
// not an event. That is the only time anything here records.
//
// A terminal sees all of it. That is precisely why none of it is here, and why
// adding a `String` parameter to any case below is the change that would break
// the promise on wortel.sh/privacy. If a new question needs a value that is not
// a small closed set, the answer is a bucket (see CountBucket) or no event.
//
// Counts are buckets and not numbers for the same reason: "8+ sessions" answers
// the question, while "37 sessions" is a number that, combined with two others,
// starts to describe one particular person's machine.
// ==========================================================================

/// One thing worth knowing, with the little that describes it.
enum TelemetryEvent: Equatable {
    /// Cold launch. `sessions` is how many were restored, which is the single
    /// most useful number about how this app is actually used.
    ///
    /// `first` is the launch that made the install id, which is what turns a
    /// download count into "and then opened it, and came back a week later".
    /// `previousExit` is how the run before this one ended: the crash and
    /// force-quit rate per version, from a marker file and nothing else (see
    /// `ExitMarker`). `notifications` is whether macOS lets attention reach
    /// anyone outside the window, which decides how much the feature can do.
    case appLaunched(sessions: CountBucket, agentsResumed: CountBucket, first: Bool,
                     previousExit: PreviousExit, notifications: NotificationState)

    /// Quit, with how long it ran. Answers whether Wortel is opened for a task
    /// or left up all day, which is a different product either way.
    case appQuit(uptime: DurationBucket)

    /// A session was started, and how. `via` is the whole point: it says
    /// whether the `wortel` command is used by anyone at all.
    case sessionCreated(via: SessionOrigin, command: Bool)

    /// Renamed, by hand or by the auto-namer. Whether auto-naming earns its
    /// keep is visible in the ratio and nowhere else.
    case sessionRenamed(automatic: Bool)

    /// The inspector was opened on a pane. Changes, History and Files are three
    /// separate bets and this is how they are told apart.
    case inspectorShown(pane: InspectorPaneKind, via: PanelOrigin)

    /// A file preview was opened, on which view, and whether as a tab or a
    /// window. Tabs are how a file opens now; `where` says whether the window
    /// is still earning its code.
    case previewOpened(mode: PreviewKind, where: PreviewPlace)

    /// A tab was opened (not brought forward: new to its session's rows), what
    /// kind, and in which area. Tabs and the browser were the biggest bet of
    /// their release, and this is the one number that says if they're used.
    case tabOpened(kind: TabOpenedKind, area: TabArea)

    /// ⌘P or ⇧⌘P was opened and closed, and how. Says whether the palette is a
    /// habit, which half of it is used, and how often it's opened for nothing.
    case paletteUsed(mode: PaletteMode, result: PaletteResult)

    /// A commit from the Changes pane, and where its message came from. The
    /// on-device drafter has real upkeep; this says whether it's used, and
    /// whether what it drafts is kept as it is.
    case commitMade(message: CommitMessageSource)

    /// The running-processes list was opened, and roughly how much was in it.
    /// `orphans` is the question this feature exists to answer: whether servers
    /// really do outlive the sessions that started them often enough to matter.
    case processesShown(jobs: CountBucket, orphans: CountBucket)

    /// Something was quit from that list. Whether it was an orphan is the whole
    /// property: quitting your own session's server is tidying, quitting one
    /// nothing was tracking any more is the feature earning its keep.
    case processQuit(orphan: Bool)

    /// A background session asked for attention. The typed kind is the feature
    /// the product's positioning rests on, so it is worth knowing which signals
    /// actually fire in the wild, and from which agent.
    case agentAttention(kind: AttentionCause, agent: AgentName)

    /// An agent was started in a session, by the person (a resume Wortel typed
    /// itself is `agentsResumed` on launch, not this). Which agent, from the
    /// fixed list the shell integration detects, and nothing about what it was
    /// asked or where: it says which integrations deserve the work first.
    case agentStarted(kind: AgentName)

    /// An idle agent was ended to give its memory back (`AgentSleep`), which
    /// one from the fixed list, and whether its hour was up or macOS said
    /// memory was short. Whether the feature does anything at all, and
    /// whether pressure ever reaches it, are both this one count.
    case agentSlept(agent: AgentName, cause: SleepCause)

    /// A sleeping agent was resumed because its session was selected, and
    /// started. Against `agent_slept`, how much of what goes to sleep is
    /// ever wanted again.
    case agentWoke(agent: AgentName)

    /// The process that keeps every shell alive went away underneath us, with
    /// roughly how many sessions it took. After a crash, the one failure that
    /// costs people the most work, and until now visible only to the person it
    /// happened to.
    case keeperLost(sessions: CountBucket)

    /// A worktree session closed into the archive (closing one archives it),
    /// and one brought back. Whether the archive is a place people return to
    /// or a polite bin is the ratio of the two. No properties: only worktree
    /// sessions are archived, and which one is nobody's business.
    case sessionArchived
    case sessionUnarchived

    /// A reminder was set on a session, from a menu or `wortel remind`.
    /// Whether anyone comes back to sessions this way. No properties: when
    /// it is for says something about the person's day.
    case reminderSet

    /// Someone used the jump-to-next-waiting shortcut. Without this, attention
    /// looks used simply because it fires; this says whether anyone acts on it.
    case agentJumpUsed

    /// The global hotkey was used. The same question `agentJumpUsed` asks, and
    /// the only place it can be asked from: this one fires from outside the
    /// app, where no other signal in this file is watching. A system-wide chord
    /// nobody presses is a chord that should be given back to the system.
    case globalHotkeyUsed

    /// A `wortel` command was served over the socket.
    case commandRun(verb: CommandVerb)

    /// The run before this launch crashed and macOS kept a report of it. What
    /// is sent is what makes a crash fixable and nothing that describes the
    /// machine or the work on it: the kind of fault, which version and chip it
    /// was, and where in *Wortel's own code* it happened, as a number. That
    /// number means nothing without this build's dSYM, which never leaves the
    /// release machine (`scripts/symbolicate.sh`). Function names, file names,
    /// paths, other programs' frames and the report itself stay on the Mac.
    /// See `CrashReport` for the reduction.
    case appCrashed(signal: CrashSignal, exception: CrashException, site: CodeOffset?,
                    signature: CrashSignature?, version: CalVer?, arch: CrashArch)

    /// The last event this install will ever send: reporting was turned off.
    /// Sent, rather than silently stopping, because the opt-out rate is the one
    /// number that says whether opt-out was the right default. Nothing follows
    /// it, and this file has no way to say anything else about the person who
    /// sent it.
    case reportingDisabled

    /// The event name in PostHog. Snake case, one vocabulary with the website
    /// and the updates Worker, so `app_downloaded` and `app_launched` sit
    /// beside each other and the drop-off between them is one query.
    var name: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .appQuit: return "app_quit"
        case .sessionCreated: return "session_created"
        case .sessionRenamed: return "session_renamed"
        case .inspectorShown: return "inspector_shown"
        case .previewOpened: return "preview_opened"
        case .tabOpened: return "tab_opened"
        case .paletteUsed: return "palette_used"
        case .commitMade: return "commit_made"
        case .processesShown: return "processes_shown"
        case .processQuit: return "process_quit"
        case .agentAttention: return "agent_attention"
        case .agentJumpUsed: return "agent_jump_used"
        case .agentStarted: return "agent_started"
        case .agentSlept: return "agent_slept"
        case .agentWoke: return "agent_woke"
        case .keeperLost: return "keeper_lost"
        case .sessionArchived: return "session_archived"
        case .sessionUnarchived: return "session_unarchived"
        case .reminderSet: return "reminder_set"
        case .appCrashed: return "app_crashed"
        case .globalHotkeyUsed: return "global_hotkey_used"
        case .commandRun: return "command_run"
        case .reportingDisabled: return "reporting_disabled"
        }
    }

    /// The event's own properties. The device properties (version, macOS, arch)
    /// are added once by the client and are not per-event.
    var properties: [String: String] {
        switch self {
        case let .appLaunched(sessions, agentsResumed, first, previousExit, notifications):
            return ["sessions": sessions.rawValue, "agents_resumed": agentsResumed.rawValue,
                    "first": first ? "true" : "false", "previous_exit": previousExit.rawValue,
                    "notifications": notifications.rawValue]
        case let .appQuit(uptime):
            return ["uptime": uptime.rawValue]
        case let .sessionCreated(via, command):
            return ["via": via.rawValue, "command": command ? "true" : "false"]
        case let .sessionRenamed(automatic):
            return ["automatic": automatic ? "true" : "false"]
        case let .inspectorShown(pane, via):
            return ["pane": pane.rawValue, "via": via.rawValue]
        case let .previewOpened(mode, place):
            return ["mode": mode.rawValue, "where": place.rawValue]
        case let .tabOpened(kind, area):
            return ["kind": kind.rawValue, "area": area.rawValue]
        case let .paletteUsed(mode, result):
            return ["mode": mode.rawValue, "result": result.rawValue]
        case let .commitMade(message):
            return ["message": message.rawValue]
        case let .processesShown(jobs, orphans):
            return ["jobs": jobs.rawValue, "orphans": orphans.rawValue]
        case let .processQuit(orphan):
            return ["orphan": orphan ? "true" : "false"]
        case let .agentAttention(kind, agent):
            return ["kind": kind.rawValue, "agent": agent.rawValue]
        case let .agentStarted(kind):
            return ["kind": kind.rawValue]
        case let .agentSlept(agent, cause):
            return ["agent": agent.rawValue, "cause": cause.rawValue]
        case let .agentWoke(agent):
            return ["agent": agent.rawValue]
        case let .keeperLost(sessions):
            return ["sessions": sessions.rawValue]
        case let .appCrashed(signal, exception, site, signature, version, arch):
            return ["signal": signal.rawValue, "exception": exception.rawValue,
                    "site": site?.rawValue ?? "none", "signature": signature?.rawValue ?? "none",
                    "crashed_version": version?.rawValue ?? "unknown", "crashed_arch": arch.rawValue]
        case .agentJumpUsed, .globalHotkeyUsed, .reportingDisabled, .sessionArchived, .sessionUnarchived,
             .reminderSet:
            return [:]
        case let .commandRun(verb):
            return ["verb": verb.rawValue]
        }
    }
}

// ---- the closed sets ------------------------------------------------------

/// How many, roughly. Never how many exactly: see the note at the top.
enum CountBucket: String, CaseIterable {
    case zero = "0"
    case one = "1"
    case twoToThree = "2-3"
    case fourToSeven = "4-7"
    case eightPlus = "8+"

    init(_ count: Int) {
        switch count {
        case ..<1: self = .zero
        case 1: self = .one
        case 2...3: self = .twoToThree
        case 4...7: self = .fourToSeven
        default: self = .eightPlus
        }
    }
}

/// How long, roughly. The top bucket is open-ended on purpose: "this person
/// left it running for eleven days" is a fact about a person, not a product.
enum DurationBucket: String, CaseIterable {
    case underMinute = "<1m"
    case underTenMinutes = "<10m"
    case underHour = "<1h"
    case underFourHours = "<4h"
    case underDay = "<24h"
    case dayOrMore = "24h+"

    init(seconds: TimeInterval) {
        switch seconds {
        case ..<60: self = .underMinute
        case ..<600: self = .underTenMinutes
        case ..<3_600: self = .underHour
        case ..<14_400: self = .underFourHours
        case ..<86_400: self = .underDay
        default: self = .dayOrMore
        }
    }
}

/// Why an idle agent was put to sleep.
enum SleepCause: String, CaseIterable {
    /// Its time at rest was up.
    case clock
    /// macOS said memory was short.
    case pressure
}

/// Where a new session came from.
enum SessionOrigin: String {
    case menu
    case cli
    case worktree
    case restore
    /// ⌘O: a directory picked from the panel, which also created the folder
    /// pointing at it when none did yet.
    case openFolder = "open_folder"
    /// ⌥⌘N: deliberately out of every folder and back to the home directory.
    /// Its whole reason to exist is the question of whether inheriting the
    /// current directory is the right default, so it has to be countable
    /// separately from the ⌘N it sits next to.
    case home
    /// ⌃⌘N, New Terminal: a session without the command Settings names. It
    /// exists only while there is one, so its count says how often the
    /// command was not what was wanted.
    case terminal
}

/// What opened the inspector. The toolbar and the shortcut are different
/// habits, and which one people reach for decides whether the segments earn
/// their space in a toolbar this small.
enum PanelOrigin: String {
    case toolbar
    case shortcut
    case restore
}

/// Mirrors `InspectorPane` without depending on it, so the git panel cannot
/// change this file's meaning by renaming one of its own cases.
enum InspectorPaneKind: String {
    case changes
    case history
    case files
}

/// Mirrors `PreviewMode`, plus the Quick Look path that is not one of its cases.
enum PreviewKind: String {
    case source
    case diff
    case rendered
    case quickLook = "quick_look"
}

/// Where a preview opened.
enum PreviewPlace: String, CaseIterable {
    case tab
    case window
}

/// Mirrors `SideTab`, without the session's own terminal: that one is never
/// opened, it is the main area's from the start.
enum TabOpenedKind: String, CaseIterable {
    case terminal
    case browser
    case file
    case pane
}

/// Mirrors `TabRegion`.
enum TabArea: String, CaseIterable {
    case main
    case side
    case bottom
}

/// ⌘P (sessions and commands) or ⇧⌘P (commands only).
enum PaletteMode: String, CaseIterable {
    case sessions
    case commands
    /// ⌘Y, the prompts typed to agents.
    case prompts
}

/// How the palette closed: a session picked, a command run, a prompt typed
/// in, or none of them.
enum PaletteResult: String, CaseIterable {
    case session
    case command
    case prompt
    case dismissed
}

/// Where a commit's message came from: typed, drafted on-device and kept as
/// drafted, or drafted and then changed.
enum CommitMessageSource: String, CaseIterable {
    case typed
    case generated
    case edited
}

/// Mirrors `AttentionKind`.
enum AttentionCause: String {
    case needsInput = "needs_input"
    case failed
    case turnDone = "turn_done"
    case finished
}

/// How the run before this launch ended. `none` is the first launch, when
/// there was no run before. `unclean` is anything that ended without the app
/// quitting: a force quit, `kill -9`, a power cut, or a crash nobody reported.
enum PreviousExit: String, CaseIterable {
    case none
    case clean
    case unclean
    case crashed
}

// ---- crashes: every value below is built from numbers or a closed set -----

/// The signal a crash ended in. Anything else is `other`.
enum CrashSignal: String, CaseIterable {
    case segv, abrt, bus, ill, trap, fpe, kill, other

    init(reported: String?) {
        switch reported {
        case "SIGSEGV": self = .segv
        case "SIGABRT": self = .abrt
        case "SIGBUS": self = .bus
        case "SIGILL": self = .ill
        case "SIGTRAP": self = .trap
        case "SIGFPE": self = .fpe
        case "SIGKILL": self = .kill
        default: self = .other
        }
    }
}

/// The Mach exception type. `breakpoint` is what a Swift runtime trap (a
/// force unwrap of nil, an index out of range) arrives as.
enum CrashException: String, CaseIterable {
    case badAccess = "bad_access"
    case crash
    case breakpoint
    case badInstruction = "bad_instr"
    case arithmetic
    case guardViolation = "guard"
    case resource
    case other

    init(reported: String?) {
        switch reported {
        case "EXC_BAD_ACCESS": self = .badAccess
        case "EXC_CRASH": self = .crash
        case "EXC_BREAKPOINT": self = .breakpoint
        case "EXC_BAD_INSTRUCTION": self = .badInstruction
        case "EXC_ARITHMETIC": self = .arithmetic
        case "EXC_GUARD": self = .guardViolation
        case "EXC_RESOURCE": self = .resource
        default: self = .other
        }
    }
}

/// Which slice of the universal binary crashed, so the right half of the
/// dSYM is used to read the offset.
enum CrashArch: String, CaseIterable {
    case arm64, x86_64, other

    init(cpuType: String?) {
        switch cpuType {
        case "ARM-64": self = .arm64
        case "X86-64": self = .x86_64
        default: self = .other
        }
    }
}

/// An offset into Wortel's own binary, in hex. A number, and only ever made
/// from one: it says where in *our* code, and only to someone holding this
/// build's dSYM. Ten hex digits at most, which is a terabyte of code.
struct CodeOffset: Equatable {
    let value: UInt64
    init?(_ value: UInt64) {
        guard value <= 0xFF_FFFF_FFFF else { return nil }
        self.value = value
    }
    var rawValue: String { String(value, radix: 16) }
}

/// The same crash, wherever it happens: a hash of the top in-binary offsets,
/// so PostHog can group by it. Twelve hex characters of SHA-256, made from
/// numbers only.
struct CrashSignature: Equatable {
    let rawValue: String

    /// The first five offsets, top of the stack first. nil without any.
    init?(offsets: [CodeOffset]) {
        let top = offsets.prefix(5)
        guard !top.isEmpty else { return nil }
        let text = top.map(\.rawValue).joined(separator: ",")
        rawValue = SHA256.hash(data: Data(text.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// A Wortel version (`2026.46.4`), rebuilt from three integers rather than
/// passed through, so a report whose version field holds anything else
/// produces nothing rather than that text.
struct CalVer: Equatable {
    let year: Int, week: Int, release: Int

    init?(_ text: String?) {
        guard let parts = text?.split(separator: ".", omittingEmptySubsequences: false), parts.count == 3,
              let year = Int(parts[0]), let week = Int(parts[1]), let release = Int(parts[2]),
              (2000...2999).contains(year), (1...53).contains(week), (1...99).contains(release)
        else { return nil }
        (self.year, self.week, self.release) = (year, week, release)
    }

    var rawValue: String { "\(year).\(week).\(release)" }
}

/// Mirrors `Permissions.State` for notifications.
enum NotificationState: String, CaseIterable {
    case granted
    case denied
    case notAsked = "not_asked"
    case unknown
}

/// The agents the shell integration recognises, and nothing else: the list in
/// `Resources/ghostty/shell-integration/*` is already closed, so this mirrors
/// it. `noAgent` is attention raised by a plain command finishing.
///
/// Built from the detected command name in `TelemetryBridging`, which is the
/// one place a string turns into one of these. Anything unrecognised becomes
/// `other`, never the name.
enum AgentName: String, CaseIterable {
    case claude, codex, pi, gemini, opencode, goose, aider, amp, crush, cline, ollama, llm
    case cursor
    case other
    case noAgent = "none"
}

/// The `wortel` command's verbs. Mirrors `WortelCommand` rather than reading
/// its `verb` string, because that property is a wire format: it exists to be
/// parsed, and a new command would otherwise start reporting itself here
/// without anyone deciding that it should.
enum CommandVerb: String {
    case open
    case new
    case rename
    case notify
    case mark
    case remind
    case list
    case read
    case send
    case wait
    case version
}
