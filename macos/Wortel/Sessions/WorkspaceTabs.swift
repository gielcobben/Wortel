import Foundation

/// Where a session's tabs are: the main area's row, the side column's row and
/// the strip under the terminal, what's in front of each, which of the two that
/// can hide are showing, and what ⌘⇧T can bring back.
///
/// The rules, in one pure value so they can be tested without a window:
///
/// - A tab lives in exactly one row. Moving it takes it out of one and puts it
///   in another; an index taken before the move (a drop between two tabs)
///   accounts for the gap the tab left behind.
/// - The session's own terminal (`.session`) is in the main row exactly once.
///   It can be reordered there, never moved out, never closed.
/// - Any tab goes in any row, except the session's terminal (`SideTab.fits`).
/// - Putting a tab in a row brings it to the front there and shows the row.
///   Taking out the one in front brings its neighbour forward, the one to its
///   right first. The column and the strip hide when they're left empty; the
///   main row never is, it always has the terminal.
/// - Moving a file or a browser to another row makes that row where the next
///   one of its kind opens (`home(for:)`): drag one browser to the main area
///   and browsers open there. Until then, and for everything else, the column.
/// - A closed tab is remembered, newest last, 25 at most, with where it was.
///   Reopening prefers the last one closed in the row you're in; a terminal
///   comes back as a new shell (a new id) in its old place.
///
/// Session holds the same state as separate properties (they're persisted and
/// observed individually); `Session.workspace` reads them into this and writes
/// them back, and GitPanelModel does the work that isn't pure around it:
/// focus, the pane on screen, persistence.
struct WorkspaceTabs: Equatable, Sendable {
    var main: [SideTab] = [.session]
    /// The tab in front of the main row; nil is the session's terminal.
    var activeMain: SideTab?
    var side: [SideTab] = []
    var activeSide: SideTab?
    var sideVisible = false
    var bottom: [SideTab] = []
    var activeBottom: SideTab?
    var bottomVisible = false
    var closed: [ClosedTab] = []
    /// Where you last moved a tab of each kind: where the next one opens.
    var habits: [TabKind: TabRegion] = [:]

    static let closedLimit = 25

    /// Every terminal tab's id, wherever it is.
    var terminalIDs: [UUID] {
        (main + side + bottom).compactMap(\.terminalID)
    }

    /// Where a new tab opens when nothing says where: the row you last moved
    /// one of its kind to, or the column.
    func home(for tab: SideTab) -> TabRegion {
        tab.kind.flatMap { habits[$0] } ?? .side
    }

    func region(of tab: SideTab) -> TabRegion? {
        if main.contains(tab) { return .main }
        if side.contains(tab) { return .side }
        if bottom.contains(tab) { return .bottom }
        return nil
    }

    // MARK: - Taking out and putting in

    /// Take a tab out of whichever row holds it. What was in front moves to a
    /// neighbour if it was this tab, and a column or strip left empty hides.
    /// Where it was, or nil if it wasn't anywhere.
    @discardableResult
    mutating func detach(_ tab: SideTab) -> (region: TabRegion, index: Int)? {
        if let index = side.firstIndex(of: tab) {
            side.remove(at: index)
            if activeSide == tab { activeSide = Self.neighbour(in: side, of: index) }
            if side.isEmpty { sideVisible = false }
            return (.side, index)
        }
        if let index = main.firstIndex(of: tab) {
            main.remove(at: index)
            if activeMain == tab {
                // The neighbour, as nil when that's the session's own terminal.
                let next = Self.neighbour(in: main, of: index)
                activeMain = next == .session ? nil : next
            }
            return (.main, index)
        }
        if let index = bottom.firstIndex(of: tab) {
            bottom.remove(at: index)
            if activeBottom == tab { activeBottom = Self.neighbour(in: bottom, of: index) }
            if bottom.isEmpty { bottomVisible = false }
            return (.bottom, index)
        }
        return nil
    }

    /// Put a tab into a row at `index` (clamped). Doesn't bring it forward: see
    /// `bringForward`. False, and nothing changes, when the tab doesn't go
    /// there or is already somewhere.
    @discardableResult
    mutating func place(_ tab: SideTab, in region: TabRegion, at index: Int) -> Bool {
        guard tab.fits(region), self.region(of: tab) == nil else { return false }
        switch region {
        case .main: main.insert(tab, at: min(max(index, 0), main.count))
        case .side: side.insert(tab, at: min(max(index, 0), side.count))
        case .bottom: bottom.insert(tab, at: min(max(index, 0), bottom.count))
        }
        return true
    }

    /// Put a tab in front of its row and show the row.
    mutating func bringForward(_ tab: SideTab) {
        switch region(of: tab) {
        case .main?: activeMain = tab == .session ? nil : tab
        case .side?:
            activeSide = tab
            sideVisible = true
        case .bottom?:
            activeBottom = tab
            bottomVisible = true
        case nil: break
        }
    }

    /// Move a tab to `region` at `index`, or reorder it within its row. The
    /// index is one into the row as it was before the tab left it, which is
    /// what a drop between two tabs measures. The tab comes to the front of its
    /// new row. False, and nothing changes, when it isn't allowed there.
    @discardableResult
    mutating func move(_ tab: SideTab, to region: TabRegion, at index: Int) -> Bool {
        guard tab.fits(region), let from = detach(tab) else { return false }
        let target = from.region == region && from.index < index ? index - 1 : index
        place(tab, in: region, at: target)
        bringForward(tab)
        // Taken to another row: that's where its kind lives now. A reorder
        // says nothing about where things belong.
        if from.region != region, let kind = tab.kind { habits[kind] = region }
        return true
    }

    // MARK: - Closing and reopening

    /// Close a tab and remember where it was. Never the session's terminal.
    /// The row it was in, or nil if nothing was closed.
    @discardableResult
    mutating func close(_ tab: SideTab) -> TabRegion? {
        guard tab != .session, let from = detach(tab) else { return nil }
        closed.append(ClosedTab(tab: tab, region: from.region, index: from.index))
        if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
        return from.region
    }

    /// Take the tab ⌘⇧T should bring back: the last closed in `region`, or the
    /// last closed anywhere when that row has none. A terminal's is a new id.
    /// Doesn't put it anywhere; the caller does, with `reopen`'s placement.
    mutating func takeClosed(preferring region: TabRegion) -> ClosedTab? {
        guard !closed.isEmpty else { return nil }
        let index = closed.lastIndex { $0.region == region } ?? closed.count - 1
        let entry = closed.remove(at: index)
        let tab: SideTab = entry.tab.terminalID != nil ? .terminal(UUID()) : entry.tab
        return ClosedTab(tab: tab, region: entry.region, index: entry.index)
    }

    /// Reopen: bring back the tab `takeClosed` picks, in its old place, in
    /// front. A pane that's already open again somewhere just comes forward.
    /// The tab that's now in front, or nil if there was nothing to reopen.
    @discardableResult
    mutating func reopen(preferring region: TabRegion) -> SideTab? {
        guard let entry = takeClosed(preferring: region) else { return nil }
        if self.region(of: entry.tab) == nil {
            place(entry.tab, in: entry.region, at: entry.index)
        }
        bringForward(entry.tab)
        return entry.tab
    }

    // MARK: - Consistency

    /// The same layout with anything a file could have got wrong put right: the
    /// session's terminal in the main row exactly once, what's in front being
    /// something the row has, and an empty column or strip hidden. What
    /// `SessionManager.restore` applies to whatever it read.
    func normalized() -> WorkspaceTabs {
        var copy = self
        var seen = false
        copy.main = copy.main.filter { tab in
            guard tab == .session else { return true }
            defer { seen = true }
            return !seen
        }
        if !copy.main.contains(.session) { copy.main.insert(.session, at: 0) }
        if let active = copy.activeMain, active == .session || !copy.main.contains(active) {
            copy.activeMain = nil
        }
        copy.side.removeAll { $0 == .session }
        copy.bottom.removeAll { $0 == .session }
        if let active = copy.activeSide, !copy.side.contains(active) { copy.activeSide = copy.side.first }
        if copy.activeSide == nil { copy.activeSide = copy.side.first }
        if copy.side.isEmpty { copy.sideVisible = false }
        if let active = copy.activeBottom, !copy.bottom.contains(active) { copy.activeBottom = copy.bottom.first }
        if copy.activeBottom == nil { copy.activeBottom = copy.bottom.first }
        if copy.bottom.isEmpty { copy.bottomVisible = false }
        return copy
    }

    /// What comes forward when the tab at `index` leaves: the one that slid
    /// into its place, or the one before it at the end of the row.
    private static func neighbour<T>(in list: [T], of index: Int) -> T? {
        list.isEmpty ? nil : list[min(index, list.count - 1)]
    }
}
