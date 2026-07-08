import Foundation

struct PersistedSession: Codable {
    let id: UUID
    let title: String
    let cwd: String?
    let selected: Bool
}

/// Persists the session list (order, titles, cwds, selection) to
/// Application Support. App state, not user config — Vellum stays zero-config.
/// Writes are debounced; `saveNow` runs synchronously for termination.
@MainActor
final class SessionStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vellum/sessions.json")
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
