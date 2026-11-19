import Foundation

/// How one sidebar section orders its sessions: the choice under Sort By in
/// a folder's "…" menu, or the Sessions header's.
///
/// **A view over the stored order, as Sort Unread First is.** The order you
/// dragged stays in `SessionManager.sessions`; this returns a permutation of
/// one section's rows to draw, and Manual is that stored order unchanged. So
/// switching a section back to Manual gives back exactly what you had, and
/// saving and `normalizeOrder` never see a sorted list. Sort Unread First, when
/// it's on, puts its unread band over the order this returns (`SidebarSort`).
///
/// Recent is the default and means **you pressed Return in it**
/// (`Session.lastSentAt`), or it was made: what moves a chat up in a list of
/// chats. Not the agent working, which would move rows while you aim at them
/// (the "Needs You" section was dropped for that, `docs/decisions.md`).
enum SectionSort {
    enum Mode: String, CaseIterable {
        case recent, created, name, manual

        /// As the Sort By menu says it.
        var title: String {
            switch self {
            case .recent: "Recent"
            case .created: "Created"
            case .name: "Name"
            case .manual: "Manual"
            }
        }
    }

    /// What one session is sorted by.
    struct Facts: Equatable {
        /// `Session.createdAt`: nil for a session saved before it was kept.
        var created: Date?
        /// `Session.lastSentAt`.
        var sent: Date?
        /// The name its row shows.
        var name: String
    }

    /// `stored`, one section's rows in their stored order, in the order to
    /// draw them. Newest first for the two times, A to Z (as Finder sorts:
    /// "2" before "10") for names. A session with no time goes after those
    /// that have one, and ties keep their stored order, so the result never
    /// shuffles rows that are equal.
    static func order(_ stored: [UUID], mode: Mode, facts: [UUID: Facts]) -> [UUID] {
        let position = Dictionary(stored.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func byDate(_ key: (Facts) -> Date?) -> [UUID] {
            stored.sorted { a, b in
                let da = facts[a].flatMap(key), db = facts[b].flatMap(key)
                switch (da, db) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return position[a]! < position[b]!
                }
            }
        }
        switch mode {
        case .manual:
            return stored
        case .recent:
            return byDate { $0.sent ?? $0.created }
        case .created:
            return byDate(\.created)
        case .name:
            return stored.sorted { a, b in
                let na = facts[a]?.name ?? "", nb = facts[b]?.name ?? ""
                switch na.localizedStandardCompare(nb) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return position[a]! < position[b]!
                }
            }
        }
    }
}
