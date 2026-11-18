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

    /// What to select when `closing` goes: the row above it, or the row
    /// below when it is the top one. nil when it isn't drawn or is alone.
    ///
    /// `opener` is the session `closing` was made from, given only while the
    /// selection has not left `closing` since: then that row is the answer,
    /// as closing a browser tab you just opened goes back to the tab it came
    /// from. ⌘N, do the thing, ⌘W is a round trip wherever the new row was
    /// put, and at the top level that is the top of the list, far from where
    /// ⌘N was pressed. An opener with no row (closed, or folded away) is no
    /// answer, and the row above is.
    static func afterClosing<ID: Equatable>(_ closing: ID, in rows: [ID], madeFrom opener: ID? = nil) -> ID? {
        guard let index = rows.firstIndex(of: closing), rows.count > 1 else { return nil }
        if let opener, opener != closing, rows.contains(opener) { return opener }
        return index > 0 ? rows[index - 1] : rows[index + 1]
    }
}
