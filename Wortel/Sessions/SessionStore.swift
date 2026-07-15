import Foundation

struct PersistedSession: Codable {
    let id: UUID
    let name: String
    let title: String
    let cwd: String?
    let selected: Bool
    /// Whether the user explicitly named this session; auto-naming skips these.
    let nameIsUserSet: Bool

    // Tolerate older files without a `name` / `nameIsUserSet` field.
    enum CodingKeys: String, CodingKey { case id, name, title, cwd, selected, nameIsUserSet }
    init(id: UUID, name: String, title: String, cwd: String?, selected: Bool, nameIsUserSet: Bool) {
        self.id = id; self.name = name; self.title = title; self.cwd = cwd
        self.selected = selected; self.nameIsUserSet = nameIsUserSet
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
    }
}

/// Persists the session list (order, titles, cwds, selection) to
/// Application Support. App state, not user config — Wortel stays zero-config.
/// Writes are debounced; `saveNow` runs synchronously for termination.
@MainActor
final class SessionStore {
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
