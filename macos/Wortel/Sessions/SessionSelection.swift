import Foundation

/// Which sidebar rows are selected beyond the one the terminal is showing.
///
/// The git panel's `ChangeSelection` is the model, with one rule changed, and
/// it is the rule everything here bends around: **the lead is not this type's
/// to own.** It is `SessionManager.selectedID`, the session on screen, which a
/// ⌘-number, a notification or Next Waiting Session move without asking the
/// sidebar. So every operation is told the lead and keeps it selected, and the
/// only time one hands back a *different* lead is the one case that has no
/// other answer: ⌘-clicking the lead itself out of the selection.
///
/// A modifier click never moves the lead otherwise. Adding a row to the
/// selection is not looking at it: switching the terminal would start its
/// shell (surfaces are lazy) and mark it read, and selecting four unread
/// sessions to pin them must not read all four.
///
/// - **`ids`** is the selection when there is more than the lead in it, lead
///   included, and empty when there isn't. Empty is the resting state, so a
///   session that isn't in a multiple selection costs nothing to ask about.
/// - **`anchor`** is the pivot a ⇧-click measures its range from. It follows
///   the lead whenever the selection collapses (a plain click, a ⌘-number), so
///   the first ⇧-click after switching sessions measures from the session you
///   are in, not from one you clicked an hour ago.
///
/// Pure over ids and the order the rows are drawn in, so it can be tested
/// without a window, and needs to be: a range one row too wide here is a
/// session closed that you never highlighted.
struct SessionSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private(set) var anchor: UUID?

    /// More than the lead is selected: a bulk menu, the lighter pills.
    var isMultiple: Bool { ids.count > 1 }

    /// Everything selected, the lead included.
    func members(lead: UUID?) -> Set<UUID> {
        isMultiple ? ids : Set([lead].compactMap { $0 })
    }

    func contains(_ id: UUID, lead: UUID?) -> Bool {
        id == lead || ids.contains(id)
    }

    /// The selection in drawn order: the order a bulk action applies in, and
    /// the order dragged rows land in.
    func ordered(in order: [UUID], lead: UUID?) -> [UUID] {
        let members = members(lead: lead)
        return order.filter(members.contains)
    }

    // MARK: - Mouse

    /// A plain click, Esc, or the lead moving from anywhere else: the lead
    /// alone, and the anchor on it.
    mutating func collapse(to lead: UUID?) {
        ids = []
        anchor = lead
    }

    /// ⌘-click. Returns the lead afterwards: unchanged, unless `id` *was* the
    /// lead, which hands off to the nearest row still selected (the one that
    /// moves the terminal least far, as `ChangeSelection` hands its diff).
    /// ⌘-clicking the only selected row does nothing: there is always a
    /// session on screen, and so always one selected.
    mutating func toggle(_ id: UUID, lead: UUID?, in order: [UUID]) -> UUID? {
        var members = members(lead: lead)
        var lead = lead
        if members.contains(id) {
            guard members.count > 1 else { return lead }
            members.remove(id)
            if id == lead { lead = Self.nearest(to: id, among: members, in: order) }
            anchor = id
        } else {
            members.insert(id)
            anchor = id
        }
        ids = members.count > 1 ? members : []
        return lead
    }

    /// ⇧-click: the rows from the anchor to `id` *replace* the selection, the
    /// lead kept in it wherever it is, and the anchor stays put so the next
    /// ⇧-click can shrink the range as easily as grow it. With no anchor in
    /// the drawn rows (its folder folded, its session closed) it measures from
    /// the lead.
    mutating func extend(to id: UUID, lead: UUID?, in order: [UUID]) {
        let pivot = anchor.flatMap { order.contains($0) ? $0 : nil } ?? lead
        guard let pivot, let a = order.firstIndex(of: pivot), let b = order.firstIndex(of: id) else {
            return
        }
        var members = Set(order[min(a, b)...max(a, b)])
        if let lead { members.insert(lead) }
        ids = members.count > 1 ? members : []
        // Unchanged when it was in the rows; the lead when it wasn't.
        anchor = pivot
    }

    // MARK: - Refresh

    /// Keep only rows in `visible` (sessions that still exist, and are drawn),
    /// the lead always. A session closed, or folded out of sight, must not be
    /// one the next bulk Close silently takes with it.
    mutating func prune(to visible: Set<UUID>, lead: UUID?) {
        guard !ids.isEmpty || anchor != nil else { return }
        var members = ids.filter { visible.contains($0) || $0 == lead }
        if let lead, !members.isEmpty { members.insert(lead) }
        ids = members.count > 1 ? members : []
        if let anchor, !visible.contains(anchor), anchor != lead { self.anchor = lead }
    }

    // MARK: - Helpers

    /// The member closest to `id` in drawn order, searching outward, below
    /// first as `ChangeSelection` does.
    private static func nearest(to id: UUID, among members: Set<UUID>, in order: [UUID]) -> UUID? {
        guard let index = order.firstIndex(of: id) else { return order.first(where: members.contains) }
        for distance in 1..<max(2, order.count) {
            let below = index + distance
            if below < order.count, members.contains(order[below]) { return order[below] }
            let above = index - distance
            if above >= 0, members.contains(order[above]) { return order[above] }
        }
        return members.first
    }
}
