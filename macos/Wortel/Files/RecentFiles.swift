import Foundation

/// The files opened lately, for ⌘P to put first among near-equal matches.
///
/// Each open counts for less as it ages, halving every ten days (fff's
/// frecency; Firefox's address bar does the same with thirty), so a file
/// opened often last week and one opened once just now both rise.
///
/// Kept in `recent-files.json` in the data folder, 500 files at most and
/// 32 opens each. Never sent anywhere.
@MainActor
final class RecentFiles {
    static let shared = RecentFiles()

    static let limit = 500
    static let opensKept = 32
    static let halfLife: TimeInterval = 10 * 24 * 60 * 60

    /// Absolute path to when it was opened, oldest first.
    private var opens: [String: [Date]] = [:]
    private var loaded = false
    private var saveScheduled = false
    private let file: URL

    init(file: URL = DataDirectory.file("recent-files.json")) {
        self.file = file
    }

    func record(_ path: String, at date: Date = Date()) {
        load()
        var dates = opens[path] ?? []
        dates.append(date)
        if dates.count > Self.opensKept { dates.removeFirst(dates.count - Self.opensKept) }
        opens[path] = dates
        if opens.count > Self.limit {
            let oldest = opens.min { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) }
            if let oldest { opens[oldest.key] = nil }
        }
        scheduleSave()
    }

    /// How much each file under `root` counts now, by its path relative to
    /// `root`: the sum of its opens, each halved per ten days of age.
    func weights(under root: String, now: Date = Date()) -> [String: Double] {
        load()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var weights: [String: Double] = [:]
        for (path, dates) in opens where path.hasPrefix(prefix) {
            let weight = dates.reduce(0.0) { total, date in
                total + pow(0.5, max(0, now.timeIntervalSince(date)) / Self.halfLife)
            }
            weights[String(path.dropFirst(prefix.count))] = weight
        }
        return weights
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data) else { return }
        opens = decoded
    }

    /// Written a moment later, once, however many opens came in between.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            guard let data = try? JSONEncoder().encode(opens) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
