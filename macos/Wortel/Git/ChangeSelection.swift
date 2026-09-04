import Foundation

/// Which rows of the changes list are selected, and which one the diff follows.
///
/// A pure value type over row **ids**, deliberately knowing nothing about
/// `GitFileChange`, AppKit or the panel: every caller hands it the list's current
/// order and gets a new selection back. That is what makes it testable without a
/// repo, and it needs to be, because every way this can be wrong is silent. A
/// range computed one row wide, an anchor that doesn't move, a lead left pointing
/// at a row that is no longer selected — none of them throw, and the first time
/// you notice is when Discard takes a file you never highlighted.
///
/// Three pieces, because a list selection is not just a set:
///
/// - **`ids`** is what is highlighted, and what a bulk action applies to.
/// - **`lead`** is the row whose diff is shown, and where ↑/↓ move from. Always
///   an element of `ids` when the selection isn't empty; that invariant is this
///   type's whole job.
/// - **`anchor`** is the pivot a ⇧-click or ⇧↑/⇧↓ measures its range from, which
///   is why it survives a range changing shape and only moves on a plain or
///   ⌘-click. Without it, extending twice measures from the row you last landed
///   on and the range can only grow.
struct ChangeSelection: Equatable {
    private(set) var ids: Set<String> = []
    private(set) var lead: String?
    private(set) var anchor: String?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    var isMultiple: Bool { ids.count > 1 }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The selection in list order, which is the order any bulk action reports
    /// and applies in. `ids` is a set because every row asks whether it's in it.
    func ordered(in ordered: [String]) -> [String] {
        ordered.filter(ids.contains)
    }

    // MARK: - Mouse

    /// A plain click, or any programmatic selection: exactly one row, and it
    /// becomes both the lead and the anchor of whatever range comes next.
    mutating func select(_ id: String?) {
        guard let id else {
            ids = []
            lead = nil
            anchor = nil
            return
        }
        ids = [id]
        lead = id
        anchor = id
    }

    /// ⌘-click: add or remove one row, leaving the rest of the selection alone.
    ///
    /// Removing the lead is the case worth spelling out. The diff pane is showing
    /// that row, so the lead has to go somewhere, and the nearest still-selected
    /// row in list order is the only answer that doesn't jump the pane to the far
    /// end of the list. Deselecting the last row empties the selection outright.
    mutating func toggle(_ id: String, in order: [String]) {
        if ids.contains(id) {
            ids.remove(id)
            if lead == id { lead = nearestSelected(to: id, in: order) }
            anchor = ids.isEmpty ? nil : id
        } else {
            ids.insert(id)
            lead = id
            anchor = id
        }
    }

    /// ⇧-click: the closed range between the anchor and `id` *replaces* the
    /// selection, and the anchor stays put so the next ⇧-click can shrink the
    /// range as easily as grow it. With no anchor yet (or one that has since been
    /// discarded), this is just a click.
    mutating func extend(to id: String, in order: [String]) {
        guard let anchor, let range = closedRange(from: anchor, to: id, in: order) else {
            select(id)
            return
        }
        ids = Set(range)
        lead = id
        // anchor deliberately unchanged.
    }

    mutating func selectAll(in order: [String]) {
        guard !order.isEmpty else { return }
        ids = Set(order)
        if lead == nil || !ids.contains(lead!) { lead = order.first }
        if anchor == nil || !ids.contains(anchor!) { anchor = lead }
    }

    // MARK: - Keyboard

    /// ↑/↓ (`extending` false) and ⇧↑/⇧↓ (true). Returns whether the lead moved,
    /// so the caller knows to load a diff and scroll.
    ///
    /// Extending re-derives the whole range from the anchor rather than adding
    /// the row it just stepped onto: that is what makes ⇧↓ then ⇧↑ shrink the
    /// selection back instead of leaving the row behind, selected, with no way to
    /// tell that it still is.
    @discardableResult
    mutating func move(by delta: Int, in order: [String], extending: Bool) -> Bool {
        guard !order.isEmpty else { return false }
        guard let lead, let index = order.firstIndex(of: lead) else {
            select(order.first)
            return true
        }
        let next = max(0, min(order.count - 1, index + delta))
        guard next != index else { return false }
        let target = order[next]
        if extending {
            extend(to: target, in: order)
        } else {
            select(target)
        }
        return true
    }

    // MARK: - Refresh

    /// Drop rows that no longer exist. Every action here ends in a `git status`,
    /// and the rows a discard or a stage just consumed come back gone: a stale id
    /// left in the set is a file the *next* bulk action would silently include if
    /// its path reappeared with the same status.
    mutating func prune(to order: [String]) {
        let alive = Set(order)
        ids.formIntersection(alive)
        if let lead, !alive.contains(lead) { self.lead = nil }
        if let anchor, !alive.contains(anchor) { self.anchor = nil }
        if lead == nil { lead = order.first(where: ids.contains) }
        if anchor == nil { anchor = lead }
    }

    // MARK: - Helpers

    private func closedRange(from: String, to: String, in order: [String]) -> ArraySlice<String>? {
        guard let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) else { return nil }
        return order[min(a, b)...max(a, b)]
    }

    /// The selected row closest to `id` in list order, searching outward. Used
    /// when the lead is deselected and has to hand off to a row that is still
    /// highlighted.
    private func nearestSelected(to id: String, in order: [String]) -> String? {
        guard let index = order.firstIndex(of: id) else { return order.first(where: ids.contains) }
        for distance in 1..<max(2, order.count) {
            let below = index + distance
            if below < order.count, ids.contains(order[below]) { return order[below] }
            let above = index - distance
            if above >= 0, ids.contains(order[above]) { return order[above] }
        }
        return nil
    }
}
