import Foundation

struct PersistedSession: Codable {
    let id: UUID
    let name: String
    let title: String
    let cwd: String?
    let selected: Bool
    /// Whether the user explicitly named this session; auto-naming skips these.
    let nameIsUserSet: Bool
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

    // Tolerate older files without a `name` / `nameIsUserSet` field.
    enum CodingKeys: String, CodingKey { case id, name, title, cwd, selected, nameIsUserSet, gitPanelVisible }
    init(id: UUID, name: String, title: String, cwd: String?, selected: Bool,
         nameIsUserSet: Bool, gitPanelVisible: Bool?) {
        self.id = id; self.name = name; self.title = title; self.cwd = cwd
        self.selected = selected; self.nameIsUserSet = nameIsUserSet
        self.gitPanelVisible = gitPanelVisible
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "shell"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Session"
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        // Older sessions (named before auto-naming existed) are treated as
        // user-set, so the feature never surprises anyone by relabelling them.
        nameIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .nameIsUserSet) ?? true
        // Left nil for older files rather than defaulted here: what an absent
        // field should fall back to is a migration decision, and this type stays
        // a plain reading of the file. `SessionManager.restore` resolves it.
        gitPanelVisible = try c.decodeIfPresent(Bool.self, forKey: .gitPanelVisible)
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
