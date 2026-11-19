import Foundation

/// View ▸ Sort Unread First: the order one sidebar section is *drawn* in.
///
/// **A view over the stored order, never a rewrite of it.** The manual order
/// (what you dragged) stays in `SessionManager.sessions` and the pins; this
/// takes it and returns a permutation for the outline to draw. Turning the
/// sort off is then just drawing the manual order again, exactly, and nothing
/// that walks the stored list (saving, `normalizeOrder`) ever sees a sorted
/// one. The keys that mean a row on screen (⌘1-9, ⌥⌘↑/↓) read the drawn
/// order instead.
///
/// Within a section, sessions that want you come first: louder kinds before
/// quieter (`AttentionKind.priority`), a hollow unread ring after every live
/// dot, and the most recent first among equals. Everything else keeps its
/// manual order beneath them.
///
/// Two rules keep rows from moving while you're using them, and they are the
/// part worth testing, because both fail as a row that jumps away from the
/// pointer rather than as anything that throws:
///
/// - **The selected row holds still** (`holding`). It was marked read the
///   moment you selected it, so a pure sort would drop it out of the unread
///   band under your eye. So it goes on sorting by the key it was last drawn
///   with until selection leaves it, and only then by its own. Holding its
///   *key* rather than its row index is deliberate: pinned to an index, the
///   row you click as another leaves the band above it stays put while its
///   neighbours reshuffle around it, which reads as the list scrambling.
/// - **Nothing moves while a click may be on its way** (`frozen`): the pointer
///   over a row, a button down, a drag. The section is drawn as it was, and
///   catches up once the pointer leaves.
///
/// Both are held against the *sort* only. A section whose manual order
/// changed (you dragged a row) is drawn fresh, or the row you just dropped
/// would refuse to move.
///
/// Beneath the unread band is the section's own order (`base`): its Sort By
/// choice (`SectionSort`), or the manual order for Pinned and a Manual
/// section. A change there (a Return moved a session up, a name changed) is
/// the sort's too, and waits while a click may be on its way like the band
/// does. Only a change to the *manual* order is drawn at once.
enum SidebarSort {
    /// Where an unread session sorts. Only unread sessions have one.
    struct Key: Equatable {
        /// Higher is louder: an attention kind's priority, or 0 for a session
        /// that is only unread (the hollow ring, or marked by hand).
        let rank: Int
        /// When it started wanting you, for "most recent first".
        let since: Date
    }

    /// What one section was last drawn as: from which manual order, in which
    /// order, and by which keys (the held row's held one among them).
    struct Drawn: Equatable {
        let manual: [UUID]
        let drawn: [UUID]
        var keys: [UUID: Key] = [:]
    }

    /// The order to draw `manual` in, and what to remember of it for next
    /// time. `base` is the section's own order of the same rows, nil for
    /// `manual` itself; the unread band goes over it.
    static func draw(manual: [UUID], base: [UUID]? = nil, keys: [UUID: Key], previous: Drawn?,
                     holding held: UUID?, frozen: Bool) -> Drawn {
        func fresh(_ keys: [UUID: Key]) -> Drawn {
            Drawn(manual: manual, drawn: sorted(base ?? manual, keys: keys), keys: keys)
        }
        guard let previous else { return fresh(keys) }
        // A reorder by hand, among the rows both orders have: draw it fresh.
        // Rows only added or removed (a session opened, closed, pinned
        // elsewhere) don't count, or the selected row would jump each time.
        let now = Set(manual), before = Set(previous.manual)
        guard previous.manual.filter(now.contains) == manual.filter(before.contains) else { return fresh(keys) }
        // Held as drawn, keys and all: when it thaws, a row selected
        // meanwhile must still hold the key it had before the click read it.
        if frozen, now == before { return previous }
        guard let held, before.contains(held) else { return fresh(keys) }
        var effective = keys
        effective[held] = previous.keys[held]
        return fresh(effective)
    }

    /// Just the order: `draw` without the memory.
    static func order(manual: [UUID], base: [UUID]? = nil, keys: [UUID: Key], previous: Drawn?,
                      holding held: UUID?, frozen: Bool) -> [UUID] {
        draw(manual: manual, base: base, keys: keys, previous: previous, holding: held, frozen: frozen).drawn
    }

    /// The plain sort, no holding: the unread band, then the rest as they are.
    static func sorted(_ manual: [UUID], keys: [UUID: Key]) -> [UUID] {
        let position = Dictionary(uniqueKeysWithValues: manual.enumerated().map { ($1, $0) })
        let unread = manual.filter { keys[$0] != nil }.sorted { a, b in
            let ka = keys[a]!, kb = keys[b]!
            if ka.rank != kb.rank { return ka.rank > kb.rank }
            if ka.since != kb.since { return ka.since > kb.since }
            return position[a]! < position[b]!
        }
        return unread + manual.filter { keys[$0] == nil }
    }
}
