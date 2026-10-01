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
    case appLaunched(sessions: CountBucket, agentsResumed: CountBucket)

    /// Quit, with how long it ran. Answers whether Wortel is opened for a task
    /// or left up all day, which is a different product either way.
    case appQuit(uptime: DurationBucket)

    /// A session was started, and how. `via` is the whole point: it says
    /// whether the `wortel` command is used by anyone at all.
    case sessionCreated(via: SessionOrigin)

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
    /// actually fire in the wild.
    case agentAttention(kind: AttentionCause)

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
        case .globalHotkeyUsed: return "global_hotkey_used"
        case .commandRun: return "command_run"
        case .reportingDisabled: return "reporting_disabled"
        }
    }

    /// The event's own properties. The device properties (version, macOS, arch)
    /// are added once by the client and are not per-event.
    var properties: [String: String] {
        switch self {
        case let .appLaunched(sessions, agentsResumed):
            return ["sessions": sessions.rawValue, "agents_resumed": agentsResumed.rawValue]
        case let .appQuit(uptime):
            return ["uptime": uptime.rawValue]
        case let .sessionCreated(via):
            return ["via": via.rawValue]
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
        case let .agentAttention(kind):
            return ["kind": kind.rawValue]
        case .agentJumpUsed, .globalHotkeyUsed, .reportingDisabled:
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
}

/// How the palette closed: a session picked, a command run, or neither.
enum PaletteResult: String, CaseIterable {
    case session
    case command
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

/// The `wortel` command's verbs. Mirrors `WortelCommand` rather than reading
/// its `verb` string, because that property is a wire format: it exists to be
/// parsed, and a new command would otherwise start reporting itself here
/// without anyone deciding that it should.
enum CommandVerb: String {
    case open
    case new
    case rename
    case notify
    case version
}
