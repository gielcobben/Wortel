import Foundation

struct PersistedSession: Codable {
    let id: UUID
    let name: String
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
    /// nil for a session outside one of Wortel's worktrees.
    let worktreeBranch: String?
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

    // Tolerate older files without a `name` / `nameSource` field.
    enum CodingKeys: String, CodingKey {
        case id, name, title, cwd, originCwd, selected, nameSource, worktreeBranch
        case gitPanelVisible, inspectorPane, sideTabs, activeSideTab, sideColumnWidth
        case bottomTabs, activeBottomTab, bottomVisible, closedTabs
        case mainTabs, activeMainTab, sideColumnLeading, browserAddresses, gitCheckout, tabHabits
        case runningAgent, runningModel, runningArgv, runningConversationID
    }
    /// Read-only: the flag `nameSource` replaced. Kept apart from `CodingKeys`
    /// so the synthesised encoder never writes it again.
    private enum LegacyKeys: String, CodingKey {
        case nameIsUserSet
    }
    init(id: UUID, name: String, title: String, cwd: String?, originCwd: String? = nil,
         selected: Bool, nameSource: String, worktreeBranch: String? = nil,
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
         runningConversationID: String? = nil) {
        self.id = id; self.name = name; self.title = title; self.cwd = cwd
        self.originCwd = originCwd
        self.selected = selected; self.nameSource = nameSource
        self.worktreeBranch = worktreeBranch
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
        worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Wortel/sessions.json")
    }

    private var pendingSave: DispatchWorkItem?

    func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return [] }
        return (try? JSONDecoder().decode([PersistedSession].self, from: data)) ?? []
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
