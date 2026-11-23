import Foundation

/// One row over in the sidebar as it is drawn: what ⌥⌘↑/↓ select, and the
/// row the selection lands on when the selected session closes.
///
/// Both read the rows on screen (Pinned first, Sort Unread First applied,
/// folded sections left out), not the stored order, which is a different
/// list as soon as anything is sorted or folded. "The next row" has to mean
/// the next one you can see.
///
/// Pure index arithmetic over the drawn rows, and a type of its own because
/// off by one here is wrong without a sound: a different session selected,
/// and nothing to say it wasn't the one you meant.
enum SidebarStep {
    /// The row `step` (+1 down, -1 up) from `current` in `rows`, wrapping at
    /// the ends. nil when there is no other row. A `current` that isn't
    /// drawn steps onto the first row going down and the last going up.
    static func neighbour<ID: Equatable>(of current: ID?, in rows: [ID], by step: Int) -> ID? {
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else {
            return step < 0 ? rows.last : rows.first
        }
        guard rows.count > 1 else { return nil }
        let n = rows.count
        return rows[((index + step) % n + n) % n]
    }

    /// What to select when `closing` goes: the session you were in before
    /// it, else the row that slides up into its place, else (it was the
    /// bottom row) the row above. nil when no row would be left, or when
    /// there is no trail to go by and `closing` isn't drawn.
    ///
    /// `trail` is the sessions this window was in before, most recent first,
    /// only the visits that counted (`visitCounts`). Going back there is the
    /// answer because the sidebar's order says little about what you were
    /// doing: new rows go on top, folders come first, and the row next to the
    /// one you close is often unrelated. ⌘N, do the thing, ⌘W is the
    /// commonest case of it, as closing a browser tab you just opened goes
    /// back to the tab it came from. A trail entry with no row (closed, moved
    /// to another window, folded away) is skipped.
    ///
    /// Without a trail, the row below: it moves up into the closed row's
    /// place, so the selection stays where it was on screen, as Finder and
    /// Mail do after a delete.
    ///
    /// `others` close with it (several rows selected): none of them is an
    /// answer, and "below" and "above" step over them.
    static func afterClosing<ID: Equatable>(_ closing: ID, in rows: [ID], trail: [ID] = [],
                                            closingToo others: [ID] = []) -> ID? {
        let staying = rows.filter { $0 != closing && !others.contains($0) }
        guard !staying.isEmpty else { return nil }
        // The way back needs no place in the rows: a row closed before the
        // outline drew it still goes back to where you were.
        if let back = trail.first(where: staying.contains) { return back }
        guard let index = rows.firstIndex(of: closing) else { return nil }
        return rows[(index + 1)...].first(where: staying.contains)
            ?? rows[..<index].last(where: staying.contains)
    }

    /// How long a session has to be in front before leaving it puts it on
    /// the trail, unless you used it: long enough that stepping through rows
    /// with ⌥⌘↓ or clicking past them leaves nothing behind.
    static let visitCountsAfter: TimeInterval = 3

    /// Whether a visit that began at `arrived` and ended at `left` goes on
    /// the trail: it lasted `visitCountsAfter`, or you typed, clicked or
    /// scrolled in it since `arrived` (`lastInput`). An unknown arrival (the
    /// session in front at launch) counts: it was where you were last time.
    static func visitCounts(arrived: Date?, left: Date, lastInput: Date?) -> Bool {
        guard let arrived else { return true }
        if let lastInput, lastInput >= arrived { return true }
        return left.timeIntervalSince(arrived) >= visitCountsAfter
    }
}
