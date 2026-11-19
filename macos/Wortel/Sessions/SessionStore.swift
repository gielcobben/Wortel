import Foundation

struct PersistedSession: Codable {
    let id: UUID
    var name: String
    let title: String
    let cwd: String?
    /// Where the session was created, as opposed to where its shell had wandered
    /// by the time this was written. What a session opened beside this one
    /// inherits. See `Session.originCwd`.
    ///
    /// Absent in every file written before sessions had one, and there is no
    /// recovering it: the origin was never recorded, so the last known `cwd` is
    /// the only candidate and `SessionManager.restore` uses it. That is exactly
    /// what the old behaviour would have inherited anyway, so the migration
    /// changes nothing on the launch that reads an old file, and the drift stops
    /// from the next session on.
    let originCwd: String?
    let selected: Bool
    /// Where the name came from, as `Session.NameSource`'s raw value: "user",
    /// "agent", "model" or "placeholder". Decides who may replace it; see
    /// `docs/session-naming.md`. A raw string for the same reason
    /// `inspectorPane` is: what an unrecognised value should mean is
    /// `SessionManager.restore`'s call.
    let nameSource: String
    /// The branch a worktree session was opened on, for the row's second line.
    /// nil for a session outside one of Wortel's worktrees. A var, like
    /// `name`, for an archived session: its folder can be renamed and its
    /// branch can be, while it waits.
    var worktreeBranch: String?
    /// The colour you gave the session, as `SessionColour`'s raw value. A raw
    /// string like `nameSource`: a colour only a newer build knows is read as
    /// none by `restore`, without failing the decode.
    let colour: String?
    /// Whether the source-control panel is open for this session. Per-session
    /// because whether you want it depends on the session: a manager sitting in
    /// your home directory never needs it, the one in a repo always does.
    ///
    /// Optional, and the two falsy cases are **not** the same: `false` is a
    /// session you deliberately hid the panel on, `nil` is a file written before
    /// visibility was per-session and which therefore said nothing about it.
    /// Only `nil` inherits the old app-wide default (see
    /// `SessionStore.legacyGitPanelVisible`) — conflating the two would reopen
    /// the panel on every session you'd hidden.
    let gitPanelVisible: Bool?

    /// Which inspector pane this session shows, as its raw value — "changes",
    /// "history", "files". Kept a `String?` rather than the enum for the same
    /// reason `gitPanelVisible` is a `Bool?`: this type is a plain reading of
    /// the file, and what an absent *or unrecognised* value should fall back to
    /// is a migration decision. `SessionManager.restore` resolves both.
    ///
    /// nil means either a file written before panes were per-session, or a
    /// session that has simply never had one chosen. Those are the same thing
    /// here — both defer to the last pane chosen anywhere — which is why, unlike
    /// `gitPanelVisible`, this needs no separate legacy flag.
    let inspectorPane: String?

    /// The side column's tabs in strip order, as `SideTab` raw values, and the
    /// one in front. nil in every file written before the column had tabs:
    /// `SessionManager.restore` turns the old visible-and-pane pair into a
    /// one-tab strip, so a session that had Changes open opens on a Changes tab.
    let sideTabs: [String]?
    let activeSideTab: String?
    /// The side column's width in points, per session. nil until the divider is
    /// first dragged in that session (and in every older file), which means
    /// "the last width chosen anywhere".
    let sideColumnWidth: Double?
    /// The strip under the session's terminal: its tabs as `SideTab` raw
    /// values, the one in front, and whether it's showing. nil in older files:
    /// no strip. Files from when the strip held terminals only list bare
    /// UUIDs; `restore` reads those as terminal tabs.
    let bottomTabs: [String]?
    let activeBottomTab: String?
    let bottomVisible: Bool?
    /// What ⌘⇧T can bring back, as `ClosedTab` raw values, newest last.
    let closedTabs: [String]?
    /// The main area's tabs, the session's terminal (`session`) among them, as
    /// `SideTab` raw values, and the one in front (nil: the terminal). Which
    /// side the column is on. nil in older files: just the terminal, trailing.
    let mainTabs: [String]?
    let activeMainTab: String?
    let sideColumnLeading: Bool?
    /// `Session.browserAddresses`, keyed by the tab id's string. nil in older
    /// files: no browsers.
    let browserAddresses: [String: String]?
    /// `Session.gitCheckout`. nil in older files: follow the terminal.
    let gitCheckout: String?
    /// `Session.tabHabits`, kind to region, raw values. nil in older files:
    /// everything opens in the column.
    let tabHabits: [String: String]?

    /// The agent CLI running in this session when the app last quit, and how it
    /// was launched — the input to resuming it on the next launch.
    ///
    /// This is recorded here rather than read back from the shell integration's
    /// marker file because a **clean quit destroys that marker**: killing the
    /// agent hands control back to the shell, which prints one last prompt on its
    /// way down, and that prompt's `precmd` deletes the marker before the next
    /// launch can ever read it. The app already knows what's running (the live
    /// badge), so it snapshots it at termination instead. Markers remain the
    /// live-state source and still cover the crash case, where nothing gets to
    /// clean up.
    let runningAgent: String?
    let runningModel: String?
    /// The exact launch command, for agents with no "continue last" primitive.
    let runningArgv: String?
    /// The agent's own conversation id, observed from the transcript file the
    /// running agent held open at quit. Exact, where `cwd` alone can only guess —
    /// it's what lets a repo with two agent sessions resume each into the right
    /// conversation. nil when it couldn't be observed; the guess still applies.
    let runningConversationID: String?
    /// Set when the agent named by `runningAgent` was asleep at the save
    /// (`AgentSleep`): "finished" or "waiting", for which clock it was on.
    /// The next launch then leaves it asleep, and resumes it when the session
    /// is selected instead of at once. A build from before this field reads
    /// `runningAgent` alone and resumes it at launch, which loses nothing.
    let agentAsleep: String?
    /// When keys last went into the session, for deep sleep's "typed and
    /// not sent": an agent with a prompt half written gets the long clock,
    /// and a relaunch must not forget that there may be one.
    let lastTypedAt: Date?
    /// The last Claude conversation this session was seen writing to, kept
    /// **whether or not** that agent is still running.
    ///
    /// `runningConversationID` answers "what was running at quit", and goes
    /// away with the agent. This answers "which conversation is this session's",
    /// which is a different fact and must not depend on the first: an agent
    /// that died for an outside reason (on 2026-10-07, a keeper force-quit from
    /// the Dock) had its id dropped at the very next save, and from then on
    /// nothing on disk said which conversation belonged where. Resuming from a
    /// surviving marker then fell back to the newest transcript per directory,
    /// which hands two sessions in one repo the same conversation. Overwritten
    /// when a newer conversation is observed; never cleared by an exit.
    let lastConversationID: String?
    /// The session's port block (`PortBlock`), by its first port. Absent in
    /// files from before sessions had one; `restore` gives those one.
    let portBase: Int?
    /// `Session.remindAt`. nil in older files, and for a session with no
    /// reminder. A var: an archived session keeps none (`archivedEntry`).
    var remindAt: Date?
    /// What the session's agent last said it was doing (`ProgramStatus.State`,
    /// by its name), when it is one that reports its own state. nil for one
    /// that does not, and in older files. Kept so that an agent still running
    /// at the next launch is taken at its word from the start, instead of
    /// being guessed at until it next says something.
    let reportedState: String?

    // Tolerate older files without a `name` / `nameSource` field.
    enum CodingKeys: String, CodingKey {
        case id, name, title, cwd, originCwd, selected, nameSource, worktreeBranch, colour
        case gitPanelVisible, inspectorPane, sideTabs, activeSideTab, sideColumnWidth
        case bottomTabs, activeBottomTab, bottomVisible, closedTabs
        case mainTabs, activeMainTab, sideColumnLeading, browserAddresses, gitCheckout, tabHabits
        case runningAgent, runningModel, runningArgv, runningConversationID
        case lastConversationID, portBase, remindAt, agentAsleep, lastTypedAt
        case reportedState
    }
    /// Read-only: the flag `nameSource` replaced. Kept apart from `CodingKeys`
    /// so the synthesised encoder never writes it again.
    private enum LegacyKeys: String, CodingKey {
        case nameIsUserSet
    }
    init(id: UUID, name: String, title: String, cwd: String?, originCwd: String? = nil,
         selected: Bool, nameSource: String, worktreeBranch: String? = nil,
         colour: String? = nil,
         gitPanelVisible: Bool?, inspectorPane: String? = nil,
         sideTabs: [String]? = nil, activeSideTab: String? = nil,
         sideColumnWidth: Double? = nil,
         bottomTabs: [String]? = nil, activeBottomTab: String? = nil, bottomVisible: Bool? = nil,
         closedTabs: [String]? = nil,
         mainTabs: [String]? = nil, activeMainTab: String? = nil,
         sideColumnLeading: Bool? = nil,
         browserAddresses: [String: String]? = nil,
         gitCheckout: String? = nil,
         tabHabits: [String: String]? = nil,
         runningAgent: String? = nil, runningModel: String? = nil, runningArgv: String? = nil,
         runningConversationID: String? = nil, lastConversationID: String? = nil,
         portBase: Int? = nil, remindAt: Date? = nil, agentAsleep: String? = nil,
         lastTypedAt: Date? = nil, reportedState: String? = nil) {
        self.id = id; self.name = name; self.title = title; self.cwd = cwd
        self.originCwd = originCwd
        self.selected = selected; self.nameSource = nameSource
        self.worktreeBranch = worktreeBranch
        self.colour = colour
        self.gitPanelVisible = gitPanelVisible
        self.inspectorPane = inspectorPane
        self.sideTabs = sideTabs
        self.activeSideTab = activeSideTab
        self.sideColumnWidth = sideColumnWidth
        self.bottomTabs = bottomTabs
        self.activeBottomTab = activeBottomTab
        self.bottomVisible = bottomVisible
        self.closedTabs = closedTabs
        self.mainTabs = mainTabs
        self.activeMainTab = activeMainTab
        self.sideColumnLeading = sideColumnLeading
        self.browserAddresses = browserAddresses
        self.gitCheckout = gitCheckout
        self.tabHabits = tabHabits
        self.runningAgent = runningAgent; self.runningModel = runningModel
        self.runningArgv = runningArgv
        self.runningConversationID = runningConversationID
        self.lastConversationID = lastConversationID
        self.portBase = portBase
        self.remindAt = remindAt
        self.agentAsleep = agentAsleep
        self.lastTypedAt = lastTypedAt
        self.reportedState = reportedState
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "shell"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Session"
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        // Left nil for older files, like the two below: what a session with no
        // recorded origin should fall back to is `restore`'s decision, not this
        // type's. (It falls back to `cwd`, the only evidence there is.)
        originCwd = try c.decodeIfPresent(String.self, forKey: .originCwd)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        // Files written before sources existed said only whether the user had
        // named the session. A `true` is exactly `user`; a `false` was a default
        // or a model guess, and both are things anything may now replace, so
        // `placeholder`. Older still (no flag at all) is treated as user-set, so
        // the feature never surprises anyone by relabelling a session they had
        // long since settled on.
        if let source = try c.decodeIfPresent(String.self, forKey: .nameSource) {
            nameSource = source
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let userSet = try legacy.decodeIfPresent(Bool.self, forKey: .nameIsUserSet) ?? true
            nameSource = userSet ? "user" : "placeholder"
        }
        // Absent for every session written before worktree sessions carried
        // their branch, and for any session outside a worktree; both mean "no
        // branch to show", and `restore` asks git for the ones that are in one.
        // So is the reftable stub, which earlier builds saved as the branch
        // (`GitWorktree.reftableStubBranch`).
        worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
            .flatMap { $0 == GitWorktree.reftableStubBranch ? nil : $0 }
        // Absent for every session never given a colour, and in every file
        // written before there were any: both mean none.
        colour = try c.decodeIfPresent(String.self, forKey: .colour)
        // Left nil for older files rather than defaulted here: what an absent
        // field should fall back to is a migration decision, and this type stays
        // a plain reading of the file. `SessionManager.restore` resolves it.
        gitPanelVisible = try c.decodeIfPresent(Bool.self, forKey: .gitPanelVisible)
        // Same reasoning, and the same deliberate nil: an absent pane is a
        // session with no preference, and which pane that should mean is
        // `restore`'s call, not this type's.
        inspectorPane = try c.decodeIfPresent(String.self, forKey: .inspectorPane)
        sideTabs = try c.decodeIfPresent([String].self, forKey: .sideTabs)
        activeSideTab = try c.decodeIfPresent(String.self, forKey: .activeSideTab)
        sideColumnWidth = try c.decodeIfPresent(Double.self, forKey: .sideColumnWidth)
        bottomTabs = try c.decodeIfPresent([String].self, forKey: .bottomTabs)
        activeBottomTab = try c.decodeIfPresent(String.self, forKey: .activeBottomTab)
        bottomVisible = try c.decodeIfPresent(Bool.self, forKey: .bottomVisible)
        closedTabs = try c.decodeIfPresent([String].self, forKey: .closedTabs)
        mainTabs = try c.decodeIfPresent([String].self, forKey: .mainTabs)
        activeMainTab = try c.decodeIfPresent(String.self, forKey: .activeMainTab)
        sideColumnLeading = try c.decodeIfPresent(Bool.self, forKey: .sideColumnLeading)
        browserAddresses = try c.decodeIfPresent([String: String].self, forKey: .browserAddresses)
        gitCheckout = try c.decodeIfPresent(String.self, forKey: .gitCheckout)
        tabHabits = try c.decodeIfPresent([String: String].self, forKey: .tabHabits)
        // Absent in files written before agent resume moved off the marker file,
        // and absent for any session with no agent running at quit — both mean
        // "nothing to resume", so a plain nil is the whole migration.
        runningAgent = try c.decodeIfPresent(String.self, forKey: .runningAgent)
        runningModel = try c.decodeIfPresent(String.self, forKey: .runningModel)
        runningArgv = try c.decodeIfPresent(String.self, forKey: .runningArgv)
        runningConversationID = try c.decodeIfPresent(String.self, forKey: .runningConversationID)
        // Older files never recorded it; the running id, when there is one, is
        // the same fact for a session whose agent was alive at quit.
        lastConversationID = try c.decodeIfPresent(String.self, forKey: .lastConversationID)
            ?? runningConversationID
        portBase = try c.decodeIfPresent(Int.self, forKey: .portBase)
        agentAsleep = try c.decodeIfPresent(String.self, forKey: .agentAsleep)
        lastTypedAt = try c.decodeIfPresent(Date.self, forKey: .lastTypedAt)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        reportedState = try c.decodeIfPresent(String.self, forKey: .reportedState)
    }
}

/// Persists the session list (order, titles, cwds, selection) to
/// Application Support. App state, not user config — Wortel stays zero-config.
/// Writes are debounced; `saveNow` runs synchronously for termination.
@MainActor
final class SessionStore {
    /// Panel visibility used to be one app-wide UserDefaults flag. Sessions
    /// persisted before it moved onto the session say nothing about it, and
    /// inherit this once so nobody's panel vanishes on update; they carry their
    /// own value from the next save on. Read-only — nothing writes this key any
    /// more, and it goes dead once every session has been re-saved.
    static var legacyGitPanelVisible: Bool {
        UserDefaults.standard.bool(forKey: "git.panelVisible")
    }

    private static var fileURL: URL {
        DataDirectory.file("sessions.json")
    }

    private var pendingSave: DispatchWorkItem?

    /// Whether the last `load` read the file, or found none. False when there
    /// was one and it couldn't be read: nothing may then be inferred from what
    /// the list *doesn't* contain (see `SessionManager.recoverOrphanedShells`).
    private(set) var loadedCleanly = true

    /// What reading the file came to. Only a file that isn't there is an
    /// empty list; one that is there and can't be read says nothing about
    /// which sessions exist.
    enum Loaded {
        case sessions([PersistedSession])
        case missing
        case unreadable
    }

    nonisolated static func read(_ url: URL) -> (Loaded, Error?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let cocoa = error as NSError
            let posix = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
            let missing = (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoSuchFileError)
                || (cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(ENOENT))
                || (posix?.domain == NSPOSIXErrorDomain && posix?.code == Int(ENOENT))
            return (missing ? .missing : .unreadable, missing ? nil : error)
        }
        do {
            return (.sessions(try JSONDecoder().decode([PersistedSession].self, from: data)), nil)
        } catch {
            return (.unreadable, error)
        }
    }

    func load() -> [PersistedSession] {
        let (loaded, error) = Self.read(Self.fileURL)
        switch loaded {
        case .sessions(let sessions):
            loadedCleanly = true
            return sessions
        case .missing:
            loadedCleanly = true
            return []
        case .unreadable:
            // Unreadable is not empty. Starting fresh is still the only way to
            // open a window, but the next save would overwrite the list, and
            // with it every session's id: the shells the keeper is holding for
            // them could then never be attached to, or closed, again. Set it
            // aside so it can be recovered. One copy, replaced each time, so a
            // file that keeps failing doesn't leave a trail. A file that is
            // there and can't be read at all is the same case as one that
            // doesn't decode.
            loadedCleanly = false
            NSLog("sessions.json unreadable, set aside: %@", String(describing: error))
            let aside = DataDirectory.file("sessions.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.copyItem(at: Self.fileURL, to: aside)
            return []
        }
    }

    func scheduleSave(_ provider: @escaping () -> [PersistedSession]) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow(provider())
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    func saveNow(_ sessions: [PersistedSession]) {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("session store save failed: %@", error.localizedDescription)
        }
    }
}

/// A worktree session you closed, waiting in ⌘P's Archived rows to be
/// continued: the session exactly as it would have been saved, its agent and
/// conversation included, and the worktree it lives in.
///
/// **Kept in a file of its own** (`archived-sessions.json`), never in
/// `sessions.json`: an older build reads that one, and would start every
/// archived session again as a live shell. This file it never opens.
struct ArchivedSession: Codable, Identifiable {
    var session: PersistedSession
    let archivedAt: Date
    /// The worktree's folder: where the shell starts again, and what's
    /// recreated from the branch when it has gone.
    let checkout: String
    /// The repository the worktree belongs to (`GitWorktree.Linked.repoHome`).
    let repoHome: String?
    /// Wortel made the worktree, so it may offer to delete it.
    let isOwned: Bool

    var id: UUID { session.id }
    var name: String { session.name }
    var folderPath: String? { SessionName.folder(of: session.name) }
    var leafName: String { SessionName.leaf(of: session.name) }
    var branch: String? { session.worktreeBranch }

    init(session: PersistedSession, archivedAt: Date, checkout: String, repoHome: String?, isOwned: Bool) {
        self.session = session
        self.archivedAt = archivedAt
        self.checkout = checkout
        self.repoHome = repoHome
        self.isOwned = isOwned
    }

    enum CodingKeys: String, CodingKey { case session, archivedAt, checkout, repoHome, isOwned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(PersistedSession.self, forKey: .session)
        checkout = try c.decode(String.self, forKey: .checkout)
        // Absent only in a hand-edited file; "now" keeps it archived.
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt) ?? Date()
        repoHome = try c.decodeIfPresent(String.self, forKey: .repoHome)
        // Unknown means not Wortel's: the one reading that can't delete work.
        isOwned = try c.decodeIfPresent(Bool.self, forKey: .isOwned) ?? false
    }
}

/// `archived-sessions.json`. Written whole on every change: it changes only
/// when you archive, restore or delete one, and it's small.
enum ArchiveStore {
    private static var fileURL: URL { DataDirectory.file("archived-sessions.json") }

    static func load(from url: URL = fileURL) -> [ArchivedSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // One unreadable entry costs that entry, not the file.
        struct Lenient: Decodable {
            let value: ArchivedSession?
            init(from decoder: Decoder) throws { value = try? ArchivedSession(from: decoder) }
        }
        guard let entries = try? JSONDecoder().decode([Lenient].self, from: data) else {
            // Not a list at all: a damaged file, or one a newer build wrote.
            // Set aside rather than read as empty, or the next archive would
            // write one entry over every session in it.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("archived sessions unreadable, kept as %@", aside.lastPathComponent)
            return []
        }
        return entries.compactMap(\.value)
    }

    static func save(_ archived: [ArchivedSession], to url: URL = fileURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if archived.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try JSONEncoder().encode(archived).write(to: url, options: .atomic)
        } catch {
            NSLog("archived sessions save failed: %@", error.localizedDescription)
        }
    }
}
