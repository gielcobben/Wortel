import Foundation

/// What `windows.json` holds per window, front to back: enough to put each
/// window back where it was, with the session it had in front.
struct PersistedWindow: Codable, Equatable {
    var id: UUID
    var frame: String?
    var selected: UUID?
}

enum WindowStore {
    static func load(from url: URL = DataDirectory.file("windows.json")) -> [PersistedWindow] {
        guard let data = try? Data(contentsOf: url),
              let windows = try? JSONDecoder().decode([PersistedWindow].self, from: data) else { return [] }
        return windows
    }

    static func save(_ windows: [PersistedWindow], to url: URL = DataDirectory.file("windows.json")) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(windows) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Which window each session goes to at launch: its own when that
    /// window is still listed, else the first. Windows left without a
    /// session are dropped, the first excepted (an empty list still has a
    /// window). An older build strips `windowID` on save, and then
    /// everything lands in the first window and nothing is lost.
    static func assign(sessions: [(id: UUID, window: UUID?)], windows: [UUID]) -> (windows: [UUID], owner: [UUID: UUID]) {
        let first = windows.first ?? UUID()
        let known = Set(windows)
        var owner: [UUID: UUID] = [:]
        for session in sessions {
            owner[session.id] = session.window.flatMap { known.contains($0) ? $0 : nil } ?? first
        }
        let used = Set(owner.values)
        let kept = ([first] + windows.dropFirst().filter(used.contains))
        return (kept, owner)
    }
}
