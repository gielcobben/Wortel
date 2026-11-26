import Foundation

/// Where a session's tabs are: the main row, the side column's row, the
/// strip's and the rows of the panes split off, what's in front of each,
/// which of the two that can hide are showing, and what ⌘⇧T can bring back.
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
/// - Except when you close a tab you opened and haven't left since: then
///   what was in front of its row when it opened comes back (a file opened
///   from Changes returns you to Changes), as a browser returns you to the tab
///   that opened one. Switching to another tab in that row ends it, and from
///   then on the neighbour rule applies.
/// - Moving a file or a browser to another row, or dropping one onto a row
///   from outside the rows, makes that row where the next one of its kind
///   opens (`home(for:)`): drag one browser to the main area and browsers
///   open there. Until then a file opens in the main area and a browser in
///   the column; everything else opens where it's asked to.
/// - A closed tab is remembered, newest last, 25 at most, with where it was.
///   Reopening prefers the last one closed in the row you're in; a terminal
///   comes back as a new shell (a new id) in its old place.
///
/// And for how the rows share the session's area (`SplitLayout` says where
/// each is; this says what is in it):
///
/// - The area is a tree whose leaves are rows of tabs. One leaf is the main
///   row, which is always there. Every other is there only while it has
///   tabs: the column, the strip, and each pane made by `split` around one
///   tab. Taking out a leaf's last tab, by closing or moving it, takes the
///   leaf out too, and its room goes to its siblings.
/// - The column and the strip are leaves like any other. They are split,
///   zoomed and sized by the rules every leaf has. One thing is still
///   theirs: they are where things open, so they have a place to appear at: the column at
///   the outer edge of the whole area (`sideLeading` says which), the strip
///   under the main row. Opened there, a leaf is at a guessed share until
///   the window gives it its size (`unsized`).
/// - Nothing is put into a pane that isn't there. A tab put in the column or
///   the strip makes its leaf.
/// - A pane's row follows the rules above: any tab but the session's
///   terminal, one in front, the neighbour or the opener coming forward. It
///   is never hidden while it exists.
/// - Splitting takes a tab from wherever it is, or a new one, and gives it a
///   pane beside the leaf asked about. Asked about a leaf that is hidden or
///   has gone, it splits the main row. A leaf's only tab can't be split off
///   its own leaf: that would be the same leaf in the same place.
/// - One leaf can be zoomed: shown alone, the others kept as they are.
///   Bringing a tab forward in another leaf, showing the column or the
///   strip, or splitting, ends it (a split made by `wortel split` doesn't:
///   it waits behind the zoom). A zoom is about now, so it isn't saved.
/// - A habit that points at a pane which has gone is no habit: the kind
///   opens where it starts. A tab closed in a pane that has gone reopens in
///   the row you're in, or in the main row.
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
    /// For a tab opened into a row and not left since: what was in front of
    /// that row when it opened. Not persisted; it is about the last few
    /// minutes, not about the layout.
    var openers: [SideTab: SideTab] = [:]
    /// The preview tab: the one file tab the next file looked at from a list
    /// replaces, drawn with an italic title so it says it will. Kept (it
    /// becomes a tab like any other) by a double-click or by moving it. Not
    /// persisted: after a relaunch it is an ordinary tab.
    var peek: SideTab?
    /// A pane's row of tabs and the one in front. Never empty in a layout
    /// that is consistent: a pane with no tabs is no pane.
    struct PaneTabs: Equatable, Sendable {
        var tabs: [SideTab]
        var active: SideTab?
    }
    /// The panes split off the main area, by id: the leaves of `layout`
    /// other than the main row.
    var panes: [UUID: PaneTabs] = [:]
    /// How the area is divided among the main row, the column, the strip
    /// and the panes. The column is a leaf of it exactly while `side` has
    /// tabs and the strip exactly while `bottom` has, showing or hidden.
    var layout = SplitLayout()
    /// The leaf shown alone, the others out of sight until it is toggled
    /// back. Not persisted.
    var zoomed: TabRegion?
    /// Which outer edge the column takes when its leaf is made: the left
    /// one, or the right.
    var sideLeading = false
    /// Leaves that were put in the tree at a guessed share, for the window
    /// to give their real size the first time it lays them out
    /// (`markSized`). Not persisted.
    var unsized: Set<SplitLayout.Leaf> = []

    /// Made consistent as it is made: a column or a strip that has tabs has
    /// its leaf in the tree, wherever the tabs came from.
    init(main: [SideTab] = [.session], activeMain: SideTab? = nil,
         side: [SideTab] = [], activeSide: SideTab? = nil, sideVisible: Bool = false,
         bottom: [SideTab] = [], activeBottom: SideTab? = nil, bottomVisible: Bool = false,
         closed: [ClosedTab] = [], habits: [TabKind: TabRegion] = [:],
         openers: [SideTab: SideTab] = [:], peek: SideTab? = nil,
         panes: [UUID: PaneTabs] = [:], layout: SplitLayout = SplitLayout(),
         zoomed: TabRegion? = nil, sideLeading: Bool = false,
         unsized: Set<SplitLayout.Leaf> = []) {
        self.main = main
        self.activeMain = activeMain
        self.side = side
        self.activeSide = activeSide
        self.sideVisible = sideVisible
        self.bottom = bottom
        self.activeBottom = activeBottom
        self.bottomVisible = bottomVisible
        self.closed = closed
        self.habits = habits
        self.openers = openers
        self.peek = peek
        self.panes = panes
        self.layout = layout
        self.zoomed = zoomed
        self.sideLeading = sideLeading
        self.unsized = unsized
        keepFixedLeaves()
    }

    static let closedLimit = 25

    /// Every terminal tab's id, wherever it is.
    var terminalIDs: [UUID] {
        allTabs.compactMap(\.terminalID)
    }

    // MARK: - Rows by region

    /// A row's tabs in order. A pane that isn't there has none.
    func tabs(in region: TabRegion) -> [SideTab] {
        switch region {
        case .main: return main
        case .side: return side
        case .bottom: return bottom
        case .pane(let id): return panes[id]?.tabs ?? []
        }
    }

    /// Every tab of the session: the main row, the column, the strip, then
    /// each pane as the layout reads, left to right and top down.
    var allTabs: [SideTab] {
        let inLayout = layout.leaves.compactMap { TabRegion($0).paneID }
        // A pane the layout doesn't know is one `normalized` will fold into
        // the main row. Until it has, its tabs still count: a terminal left
        // out here is a shell nobody closes.
        let stray = panes.keys.filter { !inLayout.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return main + side + bottom + (inLayout + stray).flatMap { panes[$0]?.tabs ?? [] }
    }

    /// The tree's leaves as regions, in reading order: the main row, each
    /// pane, and the column and the strip while they have tabs, hidden or
    /// not.
    var splitRegions: [TabRegion] { layout.leaves.map(TabRegion.init) }

    /// The leaves that are in the tree and take no room: a column or a
    /// strip that is hidden with its tabs kept.
    var hiddenLeaves: Set<SplitLayout.Leaf> {
        var hidden: Set<SplitLayout.Leaf> = []
        if !sideVisible, layout.contains(.side) { hidden.insert(.side) }
        if !bottomVisible, layout.contains(.bottom) { hidden.insert(.bottom) }
        return hidden
    }

    /// How many leaves take room: what a zoom needs more than one of.
    private var shownLeafCount: Int {
        let hidden = hiddenLeaves
        return layout.leaves.filter { !hidden.contains($0) }.count
    }

    /// Whether `region` is a place a tab can be put: always for the three
    /// fixed rows, and for a pane only while it is there.
    func exists(_ region: TabRegion) -> Bool {
        switch region {
        case .main, .side, .bottom: return true
        case .pane(let id): return panes[id] != nil
        }
    }

    /// Whether `region`'s row is on screen: a leaf that is there, not
    /// hidden, and not behind a zoom on another one.
    func isShowing(_ region: TabRegion) -> Bool {
        guard zoomed == nil || zoomed == region else { return false }
        switch region {
        case .main: return true
        case .side: return sideVisible && !side.isEmpty
        case .bottom: return bottomVisible && !bottom.isEmpty
        case .pane(let id): return panes[id] != nil
        }
    }

    /// Where a new tab opens when nothing says where: the row you last moved
    /// one of its kind to, or else where its kind starts. A file starts in
    /// the main area, where there's room to read it; a browser starts in the
    /// column, beside what it's showing you the result of.
    func home(for tab: SideTab) -> TabRegion {
        guard let kind = tab.kind else { return .side }
        // A habit for a pane that has since gone is no habit.
        if let habit = habits[kind], exists(habit) { return habit }
        return kind == .file ? .main : .side
    }

    /// Where ⌥ sends a tab, just this once: away from the main area if it's
    /// there (or, not open yet, would go there), into it otherwise.
    func elsewhere(for tab: SideTab) -> TabRegion {
        (region(of: tab) ?? home(for: tab)) == .main ? .side : .main
    }

    /// A tab of a habit kind dropped into a row from outside the rows (a file
    /// dragged out of a list): opened there, and its kind's home is there now,
    /// as if it had been dragged between rows.
    mutating func placeDropped(_ tab: SideTab, in region: TabRegion, at index: Int) {
        guard place(tab, in: region, at: index) else { return }
        bringForward(opened: tab)
        learnHome(of: tab, in: region)
    }

    /// `region` is where `tab`'s kind opens from now on, if it has a kind.
    private mutating func learnHome(of tab: SideTab, in region: TabRegion) {
        if let kind = tab.kind { habits[kind] = region }
    }

    func region(of tab: SideTab) -> TabRegion? {
        if main.contains(tab) { return .main }
        if side.contains(tab) { return .side }
        if bottom.contains(tab) { return .bottom }
        for (id, pane) in panes where pane.tabs.contains(tab) { return .pane(id) }
        return nil
    }

    // MARK: - Taking out and putting in

    /// Take a tab out of whichever row holds it. What was in front moves to a
    /// neighbour if it was this tab, and a column, a strip or a pane left
    /// empty is gone from the tree, its room given to its siblings.
    /// Where it was, or nil if it wasn't anywhere.
    @discardableResult
    mutating func detach(_ tab: SideTab) -> (region: TabRegion, index: Int)? {
        // Moved, closed or handed to another window: whichever, it is no
        // longer the tab the next file replaces.
        if peek == tab { peek = nil }
        if let index = side.firstIndex(of: tab) {
            side.remove(at: index)
            if activeSide == tab { activeSide = Self.neighbour(in: side, of: index) }
            if side.isEmpty { sideVisible = false }
            keepFixedLeaves()
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
            keepFixedLeaves()
            return (.bottom, index)
        }
        for (id, var pane) in panes {
            guard let index = pane.tabs.firstIndex(of: tab) else { continue }
            pane.tabs.remove(at: index)
            if pane.active == tab { pane.active = Self.neighbour(in: pane.tabs, of: index) }
            if pane.tabs.isEmpty {
                dissolve(id)
            } else {
                panes[id] = pane
            }
            return (.pane(id), index)
        }
        return nil
    }

    /// A pane with nothing left in it: out of the tree, its siblings taking
    /// its room. A zoom on it ends, and so does one on the main row when
    /// that is all there is again.
    private mutating func dissolve(_ id: UUID) {
        panes[id] = nil
        layout.remove(.pane(id))
        unsized.remove(.pane(id))
        if zoomed == .pane(id) || shownLeafCount < 2 { zoomed = nil }
    }

    /// The column and the strip are leaves exactly while they have tabs:
    /// put in the one that is missing, take out the one that emptied.
    ///
    /// A new one goes where it opens by default, at a share that is a guess
    /// until the window has laid it out (`unsized`): the column at the outer
    /// edge of everything, a third of the width, the strip under the main
    /// row with three tenths of its height.
    private mutating func keepFixedLeaves() {
        for leaf in [SplitLayout.Leaf.side, .bottom] {
            let has = leaf == .side ? !side.isEmpty : !bottom.isEmpty
            if has, !layout.contains(leaf) {
                let made = leaf == .side
                    ? layout.insert(.side, atRootEdge: sideLeading ? .left : .right, share: 1.0 / 3)
                    : layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
                if made { unsized.insert(leaf) }
            } else if !has {
                unsized.remove(leaf)
                guard layout.remove(leaf) else { continue }
                if zoomed == TabRegion(leaf) || shownLeafCount < 2 { zoomed = nil }
            }
        }
    }

    /// Put a tab into a row at `index` (clamped). Doesn't bring it forward: see
    /// `bringForward`. False, and nothing changes, when the tab doesn't go
    /// there, is already somewhere, or the row is a pane that isn't there
    /// (`split` is what makes one). The column's and the strip's leaf is
    /// made by their first tab.
    @discardableResult
    mutating func place(_ tab: SideTab, in region: TabRegion, at index: Int) -> Bool {
        guard tab.fits(region), exists(region), self.region(of: tab) == nil else { return false }
        switch region {
        case .main: main.insert(tab, at: min(max(index, 0), main.count))
        case .side:
            side.insert(tab, at: min(max(index, 0), side.count))
            // On screen from the moment it holds something: nothing is
            // tucked away with its tabs kept any more (`showHidden`).
            sideVisible = true
            keepFixedLeaves()
        case .bottom:
            bottom.insert(tab, at: min(max(index, 0), bottom.count))
            bottomVisible = true
            keepFixedLeaves()
        case .pane(let id):
            guard var pane = panes[id] else { return false }
            pane.tabs.insert(tab, at: min(max(index, 0), pane.tabs.count))
            panes[id] = pane
        }
        return true
    }

    /// Put a tab in front of its row and show the row: you switching to it.
    /// The tab you leave forgets where it came from; closing it later is the
    /// neighbour rule's again.
    mutating func bringForward(_ tab: SideTab) {
        if let region = region(of: tab), let previous = front(of: region), previous != tab {
            openers[previous] = nil
        }
        show(tab)
    }

    /// Put a tab just opened into its row in front, remembering what was in
    /// front there, so closing it before you switch away goes back to that.
    /// What you're leaving keeps its own origin: opening a file from a file
    /// is not leaving it.
    mutating func bringForward(opened tab: SideTab) {
        if let region = region(of: tab), let previous = front(of: region), previous != tab {
            openers[tab] = previous
        }
        show(tab)
    }

    /// Whether the session's own terminal is the tab in front of its row, and
    /// that row is up: what's on screen when the session is. A file or a page
    /// in front of it means the terminal, and what the agent wrote there,
    /// isn't. Nor is it while a pane is zoomed over the main row.
    var showsSessionTerminal: Bool {
        guard let region = region(of: .session) else { return false }
        return isShowing(region) && front(of: region) == .session
    }

    /// The tab in front of `region`'s row; the session's terminal for the
    /// main row when nothing else is.
    func front(of region: TabRegion) -> SideTab? {
        switch region {
        case .main: return activeMain ?? .session
        case .side: return activeSide
        case .bottom: return activeBottom
        case .pane(let id): return panes[id].flatMap { $0.active ?? $0.tabs.first }
        }
    }

    private mutating func show(_ tab: SideTab) {
        guard let region = region(of: tab) else { return }
        switch region {
        case .main: activeMain = tab == .session ? nil : tab
        case .side:
            activeSide = tab
            sideVisible = true
        case .bottom:
            activeBottom = tab
            bottomVisible = true
        case .pane(let id): panes[id]?.active = tab
        }
        // A tab brought forward somewhere a zoom is hiding: the zoom ends,
        // or it would have come forward out of sight. The column and the
        // strip are under a zoom like any other leaf.
        if let zoomed, zoomed != region { self.zoomed = nil }
    }

    /// Move a tab to `region` at `index`, or reorder it within its row. The
    /// index is one into the row as it was before the tab left it, which is
    /// what a drop between two tabs measures. The tab comes to the front of its
    /// new row. False, and nothing changes, when it isn't allowed there.
    /// `recordsHabit`: whether taking it to another row is you saying where
    /// its kind belongs (a drag, Move to) or not (⌥-click, just this once).
    @discardableResult
    mutating func move(_ tab: SideTab, to region: TabRegion, at index: Int,
                       recordsHabit: Bool = true) -> Bool {
        guard tab.fits(region), exists(region) else { return false }
        // A leaf's only tab, reordered in its own row: where it is already.
        // Taking it out first would take the leaf with it, and for the
        // column or the strip the share it had.
        if region != .main, self.region(of: tab) == region, tabs(in: region).count == 1 {
            if peek == tab { peek = nil }
            bringForward(tab)
            return true
        }
        guard let from = detach(tab) else { return false }
        let target = from.region == region && from.index < index ? index - 1 : index
        place(tab, in: region, at: target)
        bringForward(tab)
        // Taken to another row: that's where its kind lives now. A reorder
        // says nothing about where things belong.
        if recordsHabit, from.region != region { learnHome(of: tab, in: region) }
        return true
    }

    // MARK: - Panes of the main area

    /// Make a pane beside `region`, on `edge` of it, holding `tab` in front.
    /// A tab that is already somewhere is moved there; one that isn't is
    /// new. The pane, or nil when nothing changed: the session's terminal
    /// never leaves the main row, and a leaf's only tab can't be split off
    /// its own leaf.
    ///
    /// `region` is a leaf that is there and takes room: the main row, a
    /// pane, or the column or the strip while it is showing. Asked about a
    /// pane that has gone, or a column or strip that is hidden or empty, it
    /// is the main row that is split. `recordsHabit`, as for `move`: whether
    /// this is you saying where the tab's kind belongs (a drag) or not (a
    /// command).
    ///
    /// `keepsZoom` is for a pane you didn't make (`wortel split`): a zoom
    /// stays as it is, and the pane is there behind it when the zoom ends.
    /// What you were looking at alone is not taken from you by a script.
    @discardableResult
    mutating func split(_ region: TabRegion, on edge: SplitLayout.Edge, placing tab: SideTab,
                        id: UUID = UUID(), recordsHabit: Bool = true,
                        keepsZoom: Bool = false, spreads: Bool = false) -> TabRegion? {
        guard tab != .session, panes[id] == nil, !layout.contains(.pane(id)) else { return nil }
        var target = SplitLayout.Leaf.main
        if exists(region), layout.contains(region.leaf), !hiddenLeaves.contains(region.leaf) {
            target = region.leaf
        }
        if target != .main, self.region(of: tab) == TabRegion(target),
           tabs(in: TabRegion(target)).count == 1 { return nil }
        // Taking the tab out can take a leaf with it, when it was that
        // leaf's last. Never the one being split: that case just returned.
        detach(tab)
        // `spreads`: the leaf is too small to be two, and the row it is in
        // makes the room between all of its parts. Where there is no such
        // row it is halved after all.
        if spreads, layout.insertSpreading(.pane(id), beside: target, on: edge) {
            // Made.
        } else if !layout.insert(.pane(id), beside: target, on: edge) {
            // Only a tree that had lost its leaf, which `normalized` mends:
            // beside the main row then, rather than a tab that is nowhere.
            layout = layout.normalized()
            layout.insert(.pane(id), beside: .main, on: edge)
        }
        panes[id] = PaneTabs(tabs: [tab], active: tab)
        // A new pane is something to look at, and a zoom would hide it.
        if !keepsZoom { zoomed = nil }
        if recordsHabit { learnHome(of: tab, in: .pane(id)) }
        return .pane(id)
    }

    /// Show one leaf alone, or all of them again. Only a leaf that is
    /// there and not hidden, and only while more than one is on screen.
    mutating func toggleZoom(_ region: TabRegion) {
        guard exists(region), layout.contains(region.leaf), !hiddenLeaves.contains(region.leaf),
              shownLeafCount > 1 else { return }
        zoomed = zoomed == region ? nil : region
    }

    // MARK: - The column and the strip

    /// What a file from a build that could hide the column or the strip
    /// with its tabs kept comes to, now that nothing is hidden: the panes of
    /// a hidden one (Changes, History, Files) are closed, which loses
    /// nothing and is what ⌥⌘B does to them now, and whatever else is in
    /// it (a terminal, a file, a page) is on screen, because a shell must
    /// not be out of reach. Once, when a session is read.
    mutating func showHidden() {
        if !sideVisible {
            for tab in side where tab.pane != nil { detach(tab) }
            sideVisible = !side.isEmpty
        }
        if !bottomVisible {
            for tab in bottom where tab.pane != nil { detach(tab) }
            bottomVisible = !bottom.isEmpty
        }
        keepFixedLeaves()
    }

    /// Show or hide the column or the strip with its tabs kept: its leaf
    /// stays in the tree with the share it has. One with no tabs has nothing
    /// to show, and stays hidden. Nothing for any other region.
    ///
    /// Nothing in the app asks for this since 2026-11-26: ⌥⌘B closes the
    /// panes and ⌘J goes to the strip, and a tab placed in either shows it
    /// (`place`, `showHidden`). It is what the hidden set in `SplitLayout`
    /// is tested through, and what a hidden one from an older file is.
    ///
    /// Showing one is asking to see it, so a zoom on another leaf ends, as
    /// it does for a tab brought forward. Hiding the one that is zoomed
    /// ends the zoom too: there would be nothing left on screen.
    mutating func setVisible(_ visible: Bool, in region: TabRegion) {
        let shows: Bool
        switch region {
        case .side:
            sideVisible = visible && !side.isEmpty
            shows = sideVisible
        case .bottom:
            bottomVisible = visible && !bottom.isEmpty
            shows = bottomVisible
        case .main, .pane:
            return
        }
        guard let zoomed else { return }
        // Shown behind a zoom on another leaf, hidden while it was the one
        // zoomed, or the last thing beside the zoomed leaf going away.
        if shows ? zoomed != region : zoomed == region { self.zoomed = nil }
        if shownLeafCount < 2 { self.zoomed = nil }
    }

    /// Put the column on the other side: the flag for where its leaf is
    /// made, and a leaf that is there moves to that outer edge of the whole
    /// area, keeping the share of the width it had.
    mutating func setSideLeading(_ leading: Bool) {
        guard sideLeading != leading else { return }
        sideLeading = leading
        guard layout.contains(.side) else { return }
        let share = layout.share(of: .side, along: .row)
        layout.remove(.side)
        layout.insert(.side, atRootEdge: leading ? .left : .right, share: share ?? 1.0 / 3)
        if share == nil { unsized.insert(.side) }
    }

    /// The window has given `leaf` its real size: its share is no guess now.
    mutating func markSized(_ leaf: SplitLayout.Leaf) {
        unsized.remove(leaf)
    }

    /// Every part of every split the same size as its siblings.
    mutating func equalize() {
        layout.equalize()
    }

    // MARK: - The preview tab

    /// The row a file looked at from a list shows in: where the preview tab
    /// is, or else where files go, but never `listRegion`, the row of the list
    /// it was picked in. A preview that took the list's place would leave
    /// nothing to pick the next one from.
    func peekRegion(for tab: SideTab, avoiding listRegion: TabRegion?) -> TabRegion {
        if let peek, let region = region(of: peek), region != listRegion { return region }
        let home = home(for: tab)
        guard home == listRegion else { return home }
        return home == .main ? .side : .main
    }

    /// Whether a file is what's in front of `region`'s row, and the row is up:
    /// the one time a click in a list shows what it picked. With a terminal
    /// or a page in front, a click only selects; you didn't ask to cover it.
    func showsFile(in region: TabRegion) -> Bool {
        isShowing(region) && front(of: region)?.filePath != nil
    }

    /// Show `tab` (a file) as the preview tab, in front. A file that already
    /// has a tab comes forward instead, preview or kept. Otherwise the preview
    /// tab, if there is one, is swapped for it in its place, and if there
    /// isn't one it opens at the end of `region`'s row. The file it replaced,
    /// or nil.
    @discardableResult
    mutating func showPeek(_ tab: SideTab, in region: TabRegion) -> SideTab? {
        if self.region(of: tab) != nil {
            bringForward(tab)
            return nil
        }
        // A preview in another row than this one (the list was moved into
        // its row since) stays where it is, as an ordinary tab.
        guard let old = peek, let oldRegion = self.region(of: old), oldRegion == region else {
            peek = nil
            guard place(tab, in: region, at: .max) else { return nil }
            bringForward(opened: tab)
            peek = tab
            return nil
        }
        // In its place, taking over where it came from: closing the preview
        // still goes back to what was in front before the first file.
        switch oldRegion {
        case .main: main = main.map { $0 == old ? tab : $0 }
        case .side: side = side.map { $0 == old ? tab : $0 }
        case .bottom: bottom = bottom.map { $0 == old ? tab : $0 }
        case .pane(let id):
            if var pane = panes[id] {
                pane.tabs = pane.tabs.map { $0 == old ? tab : $0 }
                if pane.active == old { pane.active = tab }
                panes[id] = pane
            }
        }
        if activeMain == old { activeMain = tab }
        if activeSide == old { activeSide = tab }
        if activeBottom == old { activeBottom = tab }
        if let opener = openers.removeValue(forKey: old) { openers[tab] = opener }
        openers = openers.mapValues { $0 == old ? tab : $0 }
        peek = tab
        if front(of: oldRegion) != tab { bringForward(opened: tab) } else { show(tab) }
        return old
    }

    /// The preview tab, when it is what's in front of a row that's up.
    var peekInFront: SideTab? {
        guard let peek, let region = region(of: peek), front(of: region) == peek,
              showsFile(in: region) else { return nil }
        return peek
    }

    /// What a list does with `tab` for `trigger`, the list being in
    /// `listRegion`'s row:
    /// - a click or ↑/↓ shows it only while a file is in front where it
    ///   would show; with the terminal in front it only selects;
    /// - Space shows it, or closes the preview when that is in front;
    /// - a double-click shows it, and on the file the preview already shows
    ///   keeps it, as in VS Code. With a file in front, the double-click's
    ///   first click has already put it there, so it keeps at once.
    func peekAction(for tab: SideTab, _ trigger: PeekTrigger,
                    avoiding listRegion: TabRegion?) -> PeekAction {
        switch trigger {
        case .follow:
            // A file with a tab in the list's own row would come forward
            // over the list: a click there only selects.
            if let region = region(of: tab), region == listRegion { return .none }
            return showsFile(in: peekRegion(for: tab, avoiding: listRegion)) ? .show : .none
        case .toggle:
            return peekInFront != nil ? .close : .show
        case .open:
            return peek == tab ? .keep : .show
        }
    }

    /// `tab` stays: it is no longer the preview tab, and the next file looked
    /// at gets a tab of its own. A double-click on it, here or in the list.
    mutating func keep(_ tab: SideTab) {
        if peek == tab { peek = nil }
    }

    // MARK: - Closing and reopening

    /// Close a tab and remember where it was. Never the session's terminal.
    /// The row it was in, or nil if nothing was closed.
    @discardableResult
    mutating func close(_ tab: SideTab) -> TabRegion? {
        guard tab != .session, let region = region(of: tab) else { return nil }
        // Back to where it came from: only for the tab in front (closing one
        // behind changes nothing you see), and only if that is still in the
        // same row.
        let opener = front(of: region) == tab
            ? openers[tab].flatMap { self.region(of: $0) == region ? $0 : nil } : nil
        guard let from = detach(tab) else { return nil }
        // Going back to the opener is housekeeping in that row, not you
        // going there: a zoom on another part of the main area stays.
        let zoom = zoomed
        if let opener { show(opener) }
        if zoomed != zoom { zoomed = zoom }
        openers[tab] = nil
        openers = openers.filter { $0.value != tab }
        closed.append(ClosedTab(tab: tab, region: from.region, index: from.index))
        if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
        return from.region
    }

    /// Take the tab ⌘⇧T should bring back: the last closed in `region`, or the
    /// last closed anywhere when that row has none. A terminal's is a new id.
    /// Doesn't put it anywhere; the caller does, with `reopen`'s placement.
    ///
    /// The region it answers with is one that is there. A tab closed in a
    /// pane that has since gone (closing its last tab is what takes a pane
    /// away) comes back in the row you're in, or in the main row when that
    /// one has gone too or the tab doesn't go there.
    mutating func takeClosed(preferring region: TabRegion) -> ClosedTab? {
        guard !closed.isEmpty else { return nil }
        let index = closed.lastIndex { $0.region == region } ?? closed.count - 1
        let entry = closed.remove(at: index)
        let tab: SideTab = entry.tab.terminalID != nil ? .terminal(UUID()) : entry.tab
        guard !exists(entry.region) else {
            return ClosedTab(tab: tab, region: entry.region, index: entry.index)
        }
        // Its index was one into a row that no longer is: at the end.
        return ClosedTab(tab: tab, region: exists(region) && tab.fits(region) ? region : .main,
                         index: .max)
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

    /// The same layout with anything a file could have got wrong put right:
    /// every tab in one row only, the
    /// session's terminal in the main row exactly once, what's in front being
    /// something the row has, and an empty column or strip hidden. For the
    /// panes: each one a leaf of the tree and each leaf a pane with tabs, a
    /// pane the tree doesn't know folded into the main row (a terminal is
    /// never dropped for want of a place). For the column and the strip: a
    /// leaf exactly while there are tabs, so one a file from before they
    /// were leaves has no place for is put where it opens (and is `unsized`),
    /// and one with no tabs is taken out. And a zoom only on a leaf that is
    /// there and on screen. What `SessionManager.restore` applies to
    /// whatever it read.
    func normalized() -> WorkspaceTabs {
        var copy = self
        // Each tab once, in the first row that lists it (main, then the
        // column, then the strip, then the panes as the layout reads): two
        // rows claiming one terminal would give one view two places to be.
        var placed = Set<SideTab>()
        copy.main = copy.main.filter { placed.insert($0).inserted }
        copy.side = copy.side.filter { placed.insert($0).inserted }
        copy.bottom = copy.bottom.filter { placed.insert($0).inserted }
        var layout = copy.layout.normalized()
        var panes: [UUID: PaneTabs] = [:]
        for leaf in layout.leaves {
            guard case .pane(let id) = leaf else { continue }
            // The session's terminal is the main row's, whatever a pane says.
            let tabs = (copy.panes[id]?.tabs ?? []).filter { $0 != .session && placed.insert($0).inserted }
            guard !tabs.isEmpty else {
                // A leaf with no pane, or a pane with nothing left in it.
                layout.remove(leaf)
                continue
            }
            let active = copy.panes[id]?.active
            panes[id] = PaneTabs(tabs: tabs, active: active.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first)
        }
        // A pane the tree has no place for: its tabs go to the main row.
        for id in copy.panes.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where !copy.layout.contains(.pane(id)) {
            copy.main += (copy.panes[id]?.tabs ?? []).filter { $0 != .session && placed.insert($0).inserted }
        }
        copy.panes = panes
        copy.layout = layout
        copy.habits = copy.habits.filter { copy.exists($0.value) }
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
        if let peek = copy.peek, copy.region(of: peek) == nil { copy.peek = nil }
        // The column and the strip, now that their rows are what they are.
        copy.keepFixedLeaves()
        copy.unsized = copy.unsized.filter { copy.layout.contains($0) }
        if let zoomed = copy.zoomed,
           !(copy.exists(zoomed) && copy.layout.contains(zoomed.leaf)
             && !copy.hiddenLeaves.contains(zoomed.leaf) && copy.shownLeafCount > 1) {
            copy.zoomed = nil
        }
        return copy
    }

    /// What comes forward when the tab at `index` leaves: the one that slid
    /// into its place, or the one before it at the end of the row.
    private static func neighbour<T>(in list: [T], of index: Int) -> T? {
        list.isEmpty ? nil : list[min(index, list.count - 1)]
    }
}
