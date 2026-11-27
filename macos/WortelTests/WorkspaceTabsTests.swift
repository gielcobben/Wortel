import XCTest

/// `WorkspaceTabs` holds the rules for where a session's tabs are. None of them
/// throw when they're wrong: a tab lands one place off, a column stays up with
/// nothing in it, the wrong neighbour comes forward, ⌘⇧T puts back something
/// you didn't close. So each rule gets a test of its own.
final class WorkspaceTabsTests: XCTestCase {
    private let changes = SideTab.pane(.changes)
    private let history = SideTab.pane(.history)
    private let files = SideTab.pane(.files)

    private func terminal() -> SideTab { .terminal(UUID()) }

    /// A layout with the three panes in the column, Changes in front.
    private func column() -> WorkspaceTabs {
        var tabs = WorkspaceTabs()
        for tab in [changes, history, files] { tabs.place(tab, in: .side, at: .max) }
        tabs.bringForward(changes)
        return tabs
    }

    // MARK: - Reordering

    /// A drop index is measured in the row as it was, gap and all: dropping a
    /// tab after the last one puts it last, not one short.
    func testReorderToTheEndLandsLast() {
        var tabs = column()
        XCTAssertTrue(tabs.move(changes, to: .side, at: 3))
        XCTAssertEqual(tabs.side, [history, files, changes])
    }

    func testReorderToTheStartLandsFirst() {
        var tabs = column()
        tabs.move(files, to: .side, at: 0)
        XCTAssertEqual(tabs.side, [files, changes, history])
    }

    /// Dropping a tab right where it is changes nothing, from either side of
    /// its own gap.
    func testReorderOntoItselfIsANoOp() {
        for index in [1, 2] {
            var tabs = column()
            tabs.move(history, to: .side, at: index)
            XCTAssertEqual(tabs.side, [changes, history, files], "dropped at \(index)")
        }
    }

    // MARK: - Moving between rows

    func testMovingTheLastColumnTabHidesTheColumn() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .side, at: 0)
        tabs.bringForward(changes)
        XCTAssertTrue(tabs.sideVisible)

        tabs.move(changes, to: .main, at: .max)
        XCTAssertEqual(tabs.main, [.session, changes])
        XCTAssertEqual(tabs.activeMain, changes)
        XCTAssertTrue(tabs.side.isEmpty)
        XCTAssertFalse(tabs.sideVisible, "an empty column is not something to show")
    }

    /// A drop between two tabs of another row lands exactly there.
    func testMovingToAnotherRowLandsAtTheDropIndex() {
        var tabs = column()
        let a = terminal(), b = terminal()
        tabs.place(a, in: .bottom, at: 0)
        tabs.place(b, in: .bottom, at: 1)
        tabs.move(history, to: .bottom, at: 1)
        XCTAssertEqual(tabs.bottom, [a, history, b])
        XCTAssertEqual(tabs.side, [changes, files])
    }

    func testMovingATerminalToTheStripShowsIt() {
        var tabs = WorkspaceTabs()
        let shell = terminal()
        tabs.place(shell, in: .side, at: 0)
        tabs.move(shell, to: .bottom, at: .max)
        XCTAssertEqual(tabs.bottom, [shell])
        XCTAssertEqual(tabs.activeBottom, shell)
        XCTAssertTrue(tabs.bottomVisible)
    }

    /// Any tab goes in the strip, a pane and a file as much as a terminal.
    func testTheStripTakesPanesAndFilesToo() {
        var tabs = column()
        XCTAssertTrue(tabs.move(changes, to: .bottom, at: 0))
        XCTAssertEqual(tabs.bottom, [changes])
        let file = SideTab.file("/tmp/notes.md")
        tabs.place(file, in: .side, at: .max)
        XCTAssertTrue(tabs.move(file, to: .bottom, at: .max))
        XCTAssertEqual(tabs.bottom, [changes, file])
        XCTAssertEqual(tabs.activeBottom, file)
    }

    /// The session's terminal is the main area's anchor.
    func testTheSessionTerminalOnlyReordersInTheMainRow() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .main, at: .max)
        XCTAssertFalse(tabs.move(.session, to: .side, at: 0))
        XCTAssertFalse(tabs.move(.session, to: .bottom, at: 0))
        XCTAssertTrue(tabs.move(.session, to: .main, at: 2))
        XCTAssertEqual(tabs.main, [changes, .session])
        XCTAssertNil(tabs.activeMain, "in front, the session's terminal reads as nil")
    }

    func testATabIsOnlyEverInOneRow() {
        var tabs = column()
        XCTAssertFalse(tabs.place(changes, in: .main, at: 0), "already in the column")
        XCTAssertEqual(tabs.main, [.session])
    }

    // MARK: - Habits

    /// Until you've moved one, a file opens in the main area and a browser in
    /// the column; ⌥ sends each to the other.
    func testFilesStartInTheMainAreaAndBrowsersInTheColumn() {
        let tabs = WorkspaceTabs()
        XCTAssertEqual(tabs.home(for: .file("/tmp/a.md")), .main)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)
        XCTAssertEqual(tabs.elsewhere(for: .file("/tmp/a.md")), .side)
        XCTAssertEqual(tabs.elsewhere(for: .browser(UUID())), .main)
    }

    /// ⌥ on a tab that's already open goes by where it is, not where its kind
    /// goes: a file left in the column comes to the main area.
    func testElsewhereForAnOpenTabGoesByWhereItIs() {
        var tabs = WorkspaceTabs()
        let file = SideTab.file("/tmp/a.md")
        tabs.place(file, in: .side, at: 0)
        XCTAssertEqual(tabs.elsewhere(for: file), .main)
        tabs.move(file, to: .main, at: .max, recordsHabit: false)
        XCTAssertEqual(tabs.elsewhere(for: file), .side)
    }

    /// A file dropped into a row goes there, and that says nothing about
    /// where the next file opens: there is no memory of where you put one.
    func testDroppingAFileFromAListDoesNotMoveWhereFilesOpen() {
        var tabs = WorkspaceTabs()
        tabs.placeDropped(.file("/tmp/a.md"), in: .side, at: 0)
        XCTAssertEqual(tabs.region(of: .file("/tmp/a.md")), .side)
        XCTAssertEqual(tabs.home(for: .file("/tmp/b.md")), .main)
        XCTAssertEqual(tabs.elsewhere(for: .file("/tmp/b.md")), .side)
        XCTAssertTrue(tabs.habits.isEmpty)
    }

    /// One rule for where a thing opens when nothing says where: a file in
    /// the main row, a browser beside it. Moving one somewhere changes
    /// where that one is and nothing else.
    func testMovingATabDoesNotMoveWhereItsKindOpens() {
        var tabs = WorkspaceTabs()
        let browser = SideTab.browser(UUID())
        tabs.place(browser, in: .side, at: 0)
        tabs.move(browser, to: .main, at: .max)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)
        XCTAssertEqual(tabs.home(for: .file("/tmp/a.md")), .main)

        tabs.move(browser, to: .bottom, at: 0)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)
        XCTAssertTrue(tabs.habits.isEmpty)
    }

    /// A move asked for once (⌥-click) isn't a habit.
    func testAMoveThatRecordsNoHabitLeavesTheHabitAlone() {
        var tabs = WorkspaceTabs()
        let file = SideTab.file("/tmp/a.md")
        tabs.place(file, in: .main, at: .max)
        tabs.move(file, to: .side, at: 0, recordsHabit: false)
        XCTAssertEqual(tabs.region(of: file), .side)
        XCTAssertEqual(tabs.home(for: .file("/tmp/b.md")), .main)
    }

    /// Reordering says nothing about where things belong.
    func testReorderingDoesntChangeTheHabit() {
        var tabs = WorkspaceTabs()
        let a = SideTab.file("/tmp/a.md"), b = SideTab.file("/tmp/b.md")
        tabs.place(a, in: .side, at: 0)
        tabs.place(b, in: .side, at: 1)
        tabs.move(b, to: .side, at: 0)
        XCTAssertTrue(tabs.habits.isEmpty)
    }

    /// Terminals and panes open where you ask; moving them teaches nothing.
    func testTerminalsAndPanesHaveNoHabit() {
        var tabs = column()
        let shell = terminal()
        tabs.place(shell, in: .side, at: 0)
        tabs.move(shell, to: .bottom, at: 0)
        tabs.move(changes, to: .main, at: .max)
        XCTAssertTrue(tabs.habits.isEmpty)
    }

    // MARK: - Closing

    /// The tab that slid into the closed one's place comes forward; at the end
    /// of the row, the one before it.
    func testClosingTheTabInFrontBringsItsNeighbourForward() {
        var tabs = column()
        tabs.bringForward(history)
        tabs.close(history)
        XCTAssertEqual(tabs.activeSide, files)

        tabs.close(files)
        XCTAssertEqual(tabs.activeSide, changes)
    }

    /// Closing a tab that isn't in front leaves the one in front alone.
    func testClosingABackgroundTabKeepsTheFrontOne() {
        var tabs = column()
        tabs.close(files)
        XCTAssertEqual(tabs.activeSide, changes)
        XCTAssertEqual(tabs.side, [changes, history])
    }

    func testClosingTheLastStripTerminalHidesTheStrip() {
        var tabs = WorkspaceTabs()
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.bringForward(shell)
        XCTAssertEqual(tabs.close(shell), .bottom)
        XCTAssertFalse(tabs.bottomVisible)
        XCTAssertNil(tabs.activeBottom)
    }

    func testClosingTheMainRowsTabGoesBackToTheTerminal() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .main, at: .max)
        tabs.bringForward(changes)
        tabs.close(changes)
        XCTAssertNil(tabs.activeMain, "the only neighbour is the session's terminal")
        XCTAssertEqual(tabs.main, [.session])
    }

    func testTheSessionTerminalCantBeClosed() {
        var tabs = WorkspaceTabs()
        XCTAssertNil(tabs.close(.session))
        XCTAssertEqual(tabs.main, [.session])
        XCTAssertTrue(tabs.closed.isEmpty)
    }

    func testClosedTabsAreCappedAtTwentyFive() {
        var tabs = WorkspaceTabs()
        for _ in 0..<30 {
            let shell = terminal()
            tabs.place(shell, in: .side, at: .max)
            tabs.close(shell)
        }
        XCTAssertEqual(tabs.closed.count, WorkspaceTabs.closedLimit)
    }

    // MARK: - Reopening

    /// ⌘⇧T in a row brings back that row's last closed tab, even when the
    /// other row closed something since.
    func testReopenPrefersTheRowYoureIn() {
        var tabs = column()
        let strip = terminal()
        tabs.place(strip, in: .bottom, at: 0)
        tabs.close(history)
        tabs.close(strip)

        let reopened = tabs.reopen(preferring: .side)
        XCTAssertEqual(reopened, history)
        XCTAssertEqual(tabs.side, [changes, history, files], "back in its old place")
        XCTAssertEqual(tabs.closed.count, 1, "the strip's terminal is still there to reopen")
    }

    func testReopenFallsBackToTheLastClosedAnywhere() {
        var tabs = column()
        tabs.close(files)
        XCTAssertEqual(tabs.reopen(preferring: .bottom), files)
    }

    /// A terminal's shell ended with it, so it comes back as a new one.
    func testAReopenedTerminalIsANewShellInTheSamePlace() {
        var tabs = WorkspaceTabs()
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.close(shell)

        let reopened = tabs.reopen(preferring: .bottom)
        XCTAssertNotNil(reopened?.terminalID)
        XCTAssertNotEqual(reopened, shell)
        XCTAssertEqual(tabs.bottom, [reopened!])
        XCTAssertTrue(tabs.bottomVisible)
    }

    /// Reopening a pane that's open again somewhere just brings it forward
    /// there, rather than a second copy.
    func testReopeningAPaneThatsOpenAgainBringsItForward() {
        var tabs = column()
        tabs.close(files)
        tabs.place(files, in: .main, at: .max)
        XCTAssertEqual(tabs.reopen(preferring: .side), files)
        XCTAssertEqual(tabs.main, [.session, files])
        XCTAssertEqual(tabs.activeMain, files)
        XCTAssertFalse(tabs.side.contains(files))
    }

    // MARK: - Consistency

    /// What a restore applies to whatever the file said.
    func testNormalizedPutsRightWhatAFileGotWrong() {
        let broken = WorkspaceTabs(
            main: [changes, .session, .session], activeMain: history,
            side: [], activeSide: files, sideVisible: true,
            bottom: [.session], activeBottom: .terminal(UUID()), bottomVisible: true, closed: [])
        let fixed = broken.normalized()
        XCTAssertEqual(fixed.main, [changes, .session], "the terminal exactly once")
        XCTAssertNil(fixed.activeMain, "in front must be something the row has")
        XCTAssertNil(fixed.activeSide)
        XCTAssertFalse(fixed.sideVisible, "an empty column hides")
        XCTAssertTrue(fixed.bottom.isEmpty, "the session's terminal never sits in the strip")
        XCTAssertNil(fixed.activeBottom)
        XCTAssertFalse(fixed.bottomVisible)
    }

    /// A tab listed twice, or in two rows, is kept once, in the first row
    /// that lists it: one terminal must not have two places to be.
    func testNormalizedKeepsEveryTabInOneRow() {
        let shell = terminal()
        let broken = WorkspaceTabs(main: [.session, shell], side: [shell, changes, changes],
                                   bottom: [changes, history], closed: [])
        let fixed = broken.normalized()
        XCTAssertEqual(fixed.main, [.session, shell])
        XCTAssertEqual(fixed.side, [changes])
        XCTAssertEqual(fixed.bottom, [history])
    }

    func testNormalizedAddsTheTerminalToAMainRowWithoutIt() {
        XCTAssertEqual(WorkspaceTabs(main: []).normalized().main, [.session])
    }

    func testFileTabRawValuesRoundTrip() {
        let file = SideTab.file("/Users/me/Developer/wortel/README.md")
        XCTAssertEqual(SideTab(rawValue: file.rawValue), file)
        XCTAssertEqual(file.rawValue, "file:/Users/me/Developer/wortel/README.md")
    }

    func testBrowserTabRawValuesRoundTrip() {
        let browser = SideTab.browser(UUID())
        XCTAssertEqual(SideTab(rawValue: browser.rawValue), browser)
        XCTAssertNil(SideTab(rawValue: "browser:localhost"))
    }

    /// An empty tab is saved as itself, takes no habit, and is a page (its
    /// own, not a terminal's).
    func testAnEmptyTabRoundTripsAndIsAPage() {
        let id = UUID()
        let blank = SideTab.blank(id)
        XCTAssertEqual(blank.rawValue, "new:\(id.uuidString)")
        XCTAssertEqual(SideTab(rawValue: blank.rawValue), blank)
        XCTAssertNil(SideTab(rawValue: "new:nothing"))
        XCTAssertTrue(blank.isBlank)
        XCTAssertTrue(blank.isPage)
        XCTAssertNil(blank.kind)
    }

    // MARK: Reset Layout

    /// Everything gathered back: terminals and files in the main row, panes
    /// and browsers beside it, nothing closed, no strip and no split made
    /// by hand.
    func testTheStandardPresetGathersEveryTabAndClosesNone() {
        let shell = SideTab.terminal(UUID()), under = SideTab.terminal(UUID())
        let file = SideTab.file("/tmp/a.md"), page = SideTab.browser(UUID())
        var tabs = WorkspaceTabs(main: [.session, .pane(.history)], side: [.pane(.changes)], sideVisible: true,
                                 bottom: [under], bottomVisible: true)
        let pane = tabs.split(.main, on: .right, placing: shell)
        XCTAssertNotNil(pane)
        if let pane {
            tabs.place(file, in: pane, at: .max)
            tabs.place(page, in: pane, at: .max)
            tabs.place(.blank(UUID()), in: pane, at: .max)
        }
        let before = Set(tabs.allTabs.filter { !$0.isBlank })

        let reset = tabs.arranged(as: .standard)

        XCTAssertEqual(Set(reset.allTabs), before)
        XCTAssertEqual(reset.main.first, .session)
        XCTAssertEqual(Set(reset.main), [.session, under, shell, file])
        XCTAssertEqual(reset.side, [.pane(.changes), .pane(.history), page])
        XCTAssertTrue(reset.bottom.isEmpty)
        XCTAssertTrue(reset.panes.isEmpty)
        XCTAssertEqual(Set(reset.layout.leaves), [.main, .side])
        XCTAssertNil(reset.zoomed)
        XCTAssertEqual(reset.hiddenLeaves, [])
    }

    func testTheStandardPresetOfATerminalAloneIsTheTerminalAlone() {
        var tabs = WorkspaceTabs(main: [.session])
        tabs.split(.main, on: .down, placing: .terminal(UUID()))
        let reset = tabs.arranged(as: .standard)
        XCTAssertEqual(reset.layout.leaves, [.main])
        XCTAssertEqual(reset.main.count, 2)
        XCTAssertTrue(reset.side.isEmpty)
    }

    /// What you were looking at stays in front where it lands, and the
    /// habits and the zoom go back with the splits.
    func testTheStandardPresetKeepsTheFrontTabInFrontAndForgetsHabits() {
        let shell = SideTab.terminal(UUID())
        var tabs = WorkspaceTabs(main: [.session], side: [.pane(.changes), .pane(.files)],
                                 activeSide: .pane(.changes), sideVisible: true)
        let pane = tabs.split(.main, on: .right, placing: shell)
        tabs.habits = [.file: pane ?? .side]
        tabs.zoomed = pane

        let reset = tabs.arranged(as: .standard, keeping: shell)
        XCTAssertEqual(reset.activeMain, shell)
        XCTAssertEqual(reset.activeSide, .pane(.changes))
        XCTAssertTrue(reset.habits.isEmpty)
        XCTAssertNil(reset.zoomed)

        let beside = tabs.arranged(as: .standard, keeping: .pane(.files))
        XCTAssertEqual(beside.activeSide, .pane(.files))
        XCTAssertNil(beside.activeMain)
    }

    /// Which edge Changes and Files take is a choice, and stays.
    func testTheStandardPresetKeepsTheSideChangesAndFilesOpenOn() {
        var tabs = WorkspaceTabs(main: [.session], side: [.pane(.changes)], sideVisible: true, sideLeading: true)
        tabs.split(.main, on: .down, placing: .terminal(UUID()))
        let reset = tabs.arranged(as: .standard)
        XCTAssertTrue(reset.sideLeading)
        XCTAssertEqual(reset.layout.leaves.first, .side)
    }

    /// Reopen Closed Tab never brings back an empty tab.
    func testAClosedEmptyTabIsNotRemembered() {
        var tabs = WorkspaceTabs(main: [.session])
        let file = SideTab.file("/tmp/a.md"), blank = SideTab.blank(UUID())
        tabs.place(file, in: .main, at: .max)
        tabs.place(blank, in: .main, at: .max)
        _ = tabs.close(file)
        _ = tabs.close(blank)
        XCTAssertEqual(tabs.closed.map(\.tab), [file])
        XCTAssertEqual(tabs.main, [.session])
    }

    /// The last tab of a split made by hand is its empty one: choosing puts
    /// the new tab in before the empty one goes, so the split stays.
    func testAnEmptyTabHoldsItsSplitUntilItIsReplaced() {
        var tabs = WorkspaceTabs(main: [.session])
        let blank = SideTab.blank(UUID())
        let pane = tabs.split(.main, on: .right, placing: blank)
        XCTAssertNotNil(pane)
        guard let pane else { return }
        XCTAssertEqual(tabs.tabs(in: pane), [blank])
        let terminal = SideTab.terminal(UUID())
        tabs.place(terminal, in: pane, at: .max)
        _ = tabs.close(blank)
        XCTAssertEqual(tabs.tabs(in: pane), [terminal])
        XCTAssertTrue(tabs.exists(pane))
    }

    /// A browser, unlike a terminal, comes back as itself: its address is
    /// kept under its id.
    func testAReopenedBrowserKeepsItsID() {
        var tabs = WorkspaceTabs()
        let browser = SideTab.browser(UUID())
        tabs.place(browser, in: .side, at: 0)
        tabs.close(browser)
        XCTAssertEqual(tabs.reopen(preferring: .side), browser)
    }

    func testClosedTabRawValuesRoundTrip() {
        let shell = terminal()
        for entry in [ClosedTab(tab: changes, region: .side, index: 2),
                      ClosedTab(tab: shell, region: .bottom, index: 0)] {
            XCTAssertEqual(ClosedTab(rawValue: entry.rawValue), entry)
        }
        XCTAssertNil(ClosedTab(rawValue: "side:x:changes"))
    }

    // MARK: - Closing goes back to where a tab came from

    private let fileA = SideTab.file("/repo/a.swift")
    private let fileB = SideTab.file("/repo/b.swift")

    /// Changes in front, a file opened from it at the end of the row: closing
    /// the file goes back to Changes, not to its left-hand neighbour.
    func testClosingAFileOpenedFromChangesGoesBackToChanges() {
        var tabs = column()
        tabs.place(fileA, in: .side, at: .max)
        tabs.bringForward(opened: fileA)
        tabs.close(fileA)
        XCTAssertEqual(tabs.activeSide, changes)
    }

    /// Once you've switched to another tab in that row and come back, where it
    /// came from is no longer the point: the neighbour rule, as before.
    func testSwitchingAwayEndsIt() {
        var tabs = column()
        tabs.place(fileA, in: .side, at: .max)
        tabs.bringForward(opened: fileA)
        tabs.bringForward(history)
        tabs.bringForward(fileA)
        tabs.close(fileA)
        XCTAssertEqual(tabs.activeSide, files, "the neighbour: the one before it at the end of the row")
    }

    /// A file opened from a file: closing the second goes back to the first,
    /// and the first still goes back to Changes. Opening is not leaving.
    func testAFileOpenedFromAFileUnwindsInOrder() {
        var tabs = column()
        tabs.place(fileA, in: .side, at: .max)
        tabs.bringForward(opened: fileA)
        tabs.place(fileB, in: .side, at: .max)
        tabs.bringForward(opened: fileB)
        tabs.close(fileB)
        XCTAssertEqual(tabs.activeSide, fileA)
        tabs.close(fileA)
        XCTAssertEqual(tabs.activeSide, changes)
    }

    /// Closing a tab that isn't in front changes nothing you see.
    func testClosingABackgroundTabLeavesTheFront() {
        var tabs = column()
        tabs.place(fileA, in: .side, at: .max)
        tabs.bringForward(opened: fileA)
        tabs.place(fileB, in: .side, at: .max)
        tabs.bringForward(opened: fileB)
        tabs.close(fileA)
        XCTAssertEqual(tabs.activeSide, fileB)
    }

    /// The origin moved to another row since: it isn't here to go back to.
    func testAnOriginInAnotherRowIsNotFollowed() {
        var tabs = column()
        tabs.place(fileA, in: .side, at: .max)
        tabs.bringForward(opened: fileA)
        tabs.move(changes, to: .main, at: .max)
        tabs.bringForward(fileA)
        tabs.close(fileA)
        XCTAssertNotEqual(tabs.activeSide, changes)
        XCTAssertEqual(tabs.region(of: changes), .main)
    }

    /// In the main row the origin can be the session's own terminal, which is
    /// "nothing else in front".
    func testTheMainRowGoesBackToTheTerminal() {
        var tabs = WorkspaceTabs()
        tabs.place(fileA, in: .main, at: .max)
        tabs.bringForward(opened: fileA)
        XCTAssertEqual(tabs.activeMain, fileA)
        tabs.close(fileA)
        XCTAssertNil(tabs.activeMain)
    }

    // MARK: - Is the session's terminal on screen

    /// What counts as the session's terminal being on screen: it in front,
    /// not a file or page in front of it.
    func testTheTerminalIsShownUntilSomethingIsInFrontOfIt() {
        var tabs = WorkspaceTabs()
        XCTAssertTrue(tabs.showsSessionTerminal)
        tabs.place(files, in: .main, at: .max)
        tabs.bringForward(files)
        XCTAssertFalse(tabs.showsSessionTerminal)
        tabs.bringForward(.session)
        XCTAssertTrue(tabs.showsSessionTerminal)
    }

    /// Swapped into the column, the terminal is on screen only while the
    /// column is up and it is the column's front tab.
    func testATerminalInTheColumnNeedsTheColumnUp() {
        var tabs = WorkspaceTabs(main: [changes], activeMain: changes,
                                 side: [.session], activeSide: .session, sideVisible: true)
        XCTAssertTrue(tabs.showsSessionTerminal)
        tabs.sideVisible = false
        XCTAssertFalse(tabs.showsSessionTerminal)
    }

    // MARK: - The preview tab

    private let a = SideTab.file("/r/a.swift")
    private let b = SideTab.file("/r/b.swift")
    private let c = SideTab.file("/r/c.swift")

    /// The first file looked at opens in front of the main area, and the
    /// next one takes its place: one tab, however many files.
    func testTheNextFileReplacesThePreviewInPlace() {
        var tabs = column()
        tabs.place(terminal(), in: .main, at: .max)
        XCTAssertNil(tabs.showPeek(a, in: .main))
        XCTAssertEqual(tabs.peek, a)
        XCTAssertEqual(tabs.activeMain, a)
        let index = tabs.main.firstIndex(of: a)

        XCTAssertEqual(tabs.showPeek(b, in: .main), a, "the file it replaced, to let go of")
        XCTAssertEqual(tabs.peek, b)
        XCTAssertEqual(tabs.activeMain, b)
        XCTAssertFalse(tabs.main.contains(a))
        XCTAssertEqual(tabs.main.firstIndex(of: b), index, "in its place, not at the end")
    }

    /// Closing the preview goes back to what was in front before the first
    /// file, however many files it has shown since.
    func testClosingThePreviewGoesBackToTheTerminal() {
        var tabs = column()
        tabs.showPeek(a, in: .main)
        tabs.showPeek(b, in: .main)
        tabs.showPeek(c, in: .main)
        tabs.close(c)
        XCTAssertNil(tabs.activeMain, "the session's terminal is in front again")
        XCTAssertNil(tabs.peek)
    }

    /// A file that already has a tab comes forward; the preview is left as
    /// it is.
    func testAFileAlreadyOpenComesForward() {
        var tabs = column()
        tabs.place(a, in: .main, at: .max)
        tabs.showPeek(b, in: .main)
        XCTAssertNil(tabs.showPeek(a, in: .main))
        XCTAssertEqual(tabs.activeMain, a)
        XCTAssertEqual(tabs.peek, b)
        XCTAssertTrue(tabs.main.contains(b))
    }

    /// Kept, the preview is a tab like any other: the next file opens a new
    /// preview beside it.
    func testAKeptPreviewStays() {
        var tabs = column()
        tabs.showPeek(a, in: .main)
        tabs.keep(a)
        XCTAssertNil(tabs.peek)
        tabs.showPeek(b, in: .main)
        XCTAssertEqual(tabs.main, [.session, a, b])
        XCTAssertEqual(tabs.peek, b)
    }

    /// Dragging the preview somewhere is keeping it.
    func testMovingThePreviewKeepsIt() {
        var tabs = column()
        tabs.showPeek(a, in: .main)
        tabs.move(a, to: .side, at: .max)
        XCTAssertNil(tabs.peek)
    }

    /// The preview never opens in the row of the list it was picked from;
    /// with files moved to the column, the Changes list in the column sends
    /// it to the main area.
    func testThePreviewAvoidsTheListsRow() {
        var tabs = column()
        tabs.habits[.file] = .side
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: .side), .main)
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: .main), .side)
        XCTAssertEqual(WorkspaceTabs().peekRegion(for: a, avoiding: .side), .main)
    }

    /// A click follows only while a file is in front: with the terminal in
    /// front it only selects.
    func testShowsFileOnlyWithAFileInFront() {
        var tabs = column()
        XCTAssertFalse(tabs.showsFile(in: .main))
        tabs.showPeek(a, in: .main)
        XCTAssertTrue(tabs.showsFile(in: .main))
        tabs.bringForward(.session)
        XCTAssertFalse(tabs.showsFile(in: .main))
    }

    /// Showing a file while the preview sits behind a kept file brings it
    /// forward, and closing it then goes back to that kept file.
    func testAPreviewBehindComesForward() {
        var tabs = column()
        tabs.showPeek(a, in: .main)
        tabs.place(b, in: .main, at: .max)
        tabs.bringForward(b)
        tabs.showPeek(c, in: .main)
        XCTAssertEqual(tabs.activeMain, c)
        XCTAssertEqual(tabs.main, [.session, c, b])
        tabs.close(c)
        XCTAssertEqual(tabs.activeMain, b)
    }

    // MARK: - What a click, Space or a double-click does

    /// Do in `tabs` what a list does for `trigger` on `tab`, the list in the
    /// column, the way AppDelegate carries out a `PeekAction`.
    @discardableResult
    private func list(_ tabs: inout WorkspaceTabs, _ trigger: PeekTrigger, _ tab: SideTab) -> PeekAction {
        let action = tabs.peekAction(for: tab, trigger, avoiding: .side)
        switch action {
        case .none: break
        case .show: tabs.showPeek(tab, in: tabs.peekRegion(for: tab, avoiding: .side))
        case .keep: tabs.keep(tab)
        case .close: if let peek = tabs.peek { tabs.close(peek) }
        }
        return action
    }

    /// A double-click is its first click, then the double-click.
    private func doubleClick(_ tabs: inout WorkspaceTabs, _ tab: SideTab) -> PeekAction {
        list(&tabs, .follow, tab)
        return list(&tabs, .open, tab)
    }

    /// With the terminal in front a click only selects: the agent you're
    /// watching isn't covered.
    func testAClickWithTheTerminalInFrontOnlySelects() {
        var tabs = column()
        XCTAssertEqual(list(&tabs, .follow, a), .none)
        XCTAssertEqual(tabs.main, [.session])
        XCTAssertNil(tabs.activeMain)
    }

    /// From the terminal, a double-click opens the preview; clicks then go
    /// on in the same tab; a double-click on the file it shows keeps it.
    func testFromTheTerminalDoubleClickPreviewsThenDoubleClickKeeps() {
        var tabs = column()
        XCTAssertEqual(doubleClick(&tabs, a), .show)
        XCTAssertEqual(tabs.peek, a)
        XCTAssertEqual(tabs.activeMain, a)

        XCTAssertEqual(list(&tabs, .follow, b), .show)
        XCTAssertEqual(tabs.main, [.session, b], "the same tab, now on b")
        XCTAssertEqual(tabs.peek, b)

        XCTAssertEqual(list(&tabs, .open, b), .keep, "the second click of a double-click on b")
        XCTAssertNil(tabs.peek)
        XCTAssertEqual(tabs.main, [.session, b])
    }

    /// With a file in front, a double-click keeps at once, as in VS Code:
    /// its first click has put the file in the preview.
    func testWithAFileInFrontADoubleClickKeeps() {
        var tabs = column()
        list(&tabs, .toggle, a)
        XCTAssertEqual(doubleClick(&tabs, b), .keep)
        XCTAssertEqual(tabs.main, [.session, b])
        XCTAssertNil(tabs.peek)

        // The next file gets a preview of its own, beside the kept one.
        XCTAssertEqual(list(&tabs, .follow, c), .show)
        XCTAssertEqual(tabs.main, [.session, b, c])
        XCTAssertEqual(tabs.peek, c)
    }

    /// Space opens the preview from the terminal and closes it again.
    func testSpaceOpensAndCloses() {
        var tabs = column()
        XCTAssertEqual(list(&tabs, .toggle, a), .show)
        XCTAssertEqual(tabs.activeMain, a)
        XCTAssertEqual(list(&tabs, .toggle, a), .close)
        XCTAssertNil(tabs.activeMain, "back to the terminal")
        XCTAssertEqual(tabs.main, [.session])
    }

    /// Back on the terminal with the preview behind it, clicks only select
    /// again; Space brings the preview forward on the selected file.
    func testThePreviewBehindTheTerminalDoesNotFollow() {
        var tabs = column()
        list(&tabs, .toggle, a)
        tabs.bringForward(.session)
        XCTAssertEqual(list(&tabs, .follow, b), .none)
        XCTAssertEqual(tabs.peek, a)
        XCTAssertEqual(list(&tabs, .toggle, b), .show)
        XCTAssertEqual(tabs.activeMain, b)
        XCTAssertEqual(tabs.main, [.session, b])
    }

    /// A file with a tab in the list's own row isn't brought forward over
    /// the list by a click.
    func testAClickNeverCoversTheList() {
        var tabs = column()
        tabs.place(b, in: .side, at: .max)
        tabs.bringForward(changes)
        list(&tabs, .toggle, a)
        XCTAssertEqual(list(&tabs, .follow, b), .none)
        XCTAssertEqual(tabs.activeSide, changes)
    }

    /// The list moved into the preview's row: the next file opens in the
    /// other row, and the old preview stays where it was as an ordinary tab.
    func testAListMovedOntoThePreviewIsNotCovered() {
        var tabs = column()
        list(&tabs, .toggle, a)
        tabs.move(changes, to: .main, at: .max)
        XCTAssertEqual(tabs.peekRegion(for: b, avoiding: .main), .side)
        tabs.showPeek(b, in: .side)
        XCTAssertTrue(tabs.main.contains(a))
        XCTAssertEqual(tabs.activeMain, changes)
        XCTAssertEqual(tabs.peek, b)
        XCTAssertEqual(tabs.activeSide, b)
    }

    // MARK: - Panes of the main area

    private let fileC = SideTab.file("/repo/c.swift")

    /// Split a pane off the right of `tabs`' main row, holding `tab`.
    @discardableResult
    private func splitOff(_ tab: SideTab, from tabs: inout WorkspaceTabs) -> TabRegion {
        let id = UUID()
        let pane = tabs.split(.main, on: .right, placing: tab, id: id)
        XCTAssertEqual(pane, .pane(id))
        return .pane(id)
    }

    /// A region is saved as a string, a pane's with its id.
    func testRegionRawValues() {
        let id = UUID()
        XCTAssertEqual(TabRegion.main.rawValue, "main")
        XCTAssertEqual(TabRegion.side.rawValue, "side")
        XCTAssertEqual(TabRegion.bottom.rawValue, "bottom")
        XCTAssertEqual(TabRegion.pane(id).rawValue, "pane:\(id.uuidString)")
        for region in [TabRegion.main, .side, .bottom, .pane(id)] {
            XCTAssertEqual(TabRegion(rawValue: region.rawValue), region)
        }
        XCTAssertNil(TabRegion(rawValue: "pane:"))
        XCTAssertNil(TabRegion(rawValue: "pane:not-an-id"))
        XCTAssertNil(TabRegion(rawValue: id.uuidString))
        XCTAssertNil(TabRegion(rawValue: "top"))
    }

    /// Every region is a leaf of the tree, the column and the strip too.
    func testRegionsAndLeaves() {
        let id = UUID()
        XCTAssertEqual(TabRegion.main.leaf, .main)
        XCTAssertEqual(TabRegion.pane(id).leaf, .pane(id))
        XCTAssertEqual(TabRegion.side.leaf, .side)
        XCTAssertEqual(TabRegion.bottom.leaf, .bottom)
        XCTAssertEqual(TabRegion(.main), .main)
        XCTAssertEqual(TabRegion(.pane(id)), .pane(id))
        XCTAssertEqual(TabRegion(.side), .side)
        XCTAssertEqual(TabRegion(.bottom), .bottom)
        for region in [TabRegion.main, .pane(id), .side, .bottom] {
            XCTAssertTrue(region.isSplitLeaf, "\(region)")
            XCTAssertEqual(TabRegion(region.leaf), region)
        }
    }

    /// Anything goes in a pane but the session's own terminal.
    func testWhatFitsAPane() {
        let pane = TabRegion.pane(UUID())
        for tab in [changes, terminal(), fileA, SideTab.browser(UUID())] {
            XCTAssertTrue(tab.fits(pane))
        }
        XCTAssertFalse(SideTab.session.fits(pane))
        XCTAssertTrue(SideTab.session.fits(.main))
    }

    /// A tab closed in a pane is saved with the pane, colons and all, and a
    /// file's path may have colons of its own.
    func testAClosedTabInAPaneRoundTrips() {
        let id = UUID()
        let shell = terminal()
        for tab in [changes, shell, SideTab.file("/r/a:b:c.swift"), .browser(UUID())] {
            for region in [TabRegion.pane(id), .main, .side, .bottom] {
                let closed = ClosedTab(tab: tab, region: region, index: 3)
                XCTAssertEqual(ClosedTab(rawValue: closed.rawValue), closed, closed.rawValue)
            }
        }
        XCTAssertEqual(ClosedTab(tab: changes, region: .pane(id), index: 2).rawValue,
                       "pane:\(id.uuidString):2:changes")
        XCTAssertNil(ClosedTab(rawValue: "pane:\(id.uuidString):changes"))
        XCTAssertNil(ClosedTab(rawValue: "pane:nope:2:changes"))
        XCTAssertNil(ClosedTab(rawValue: "pane:\(id.uuidString):x:changes"))
    }

    // MARK: Splitting

    /// A new tab split off the main row: a pane beside it, the tab in front.
    func testSplittingMakesAPaneWithTheTabInFront() {
        let shell = terminal()
        var tabs = column()
        let pane = splitOff(shell, from: &tabs)
        let id = pane.paneID!
        XCTAssertEqual(tabs.panes[id], WorkspaceTabs.PaneTabs(tabs: [shell], active: shell))
        XCTAssertEqual(tabs.layout.leaves, [.main, .pane(id), .side], "between the main row and the column")
        XCTAssertEqual(tabs.region(of: shell), pane)
        XCTAssertEqual(tabs.tabs(in: pane), [shell])
        XCTAssertEqual(tabs.front(of: pane), shell)
        XCTAssertTrue(tabs.isShowing(pane))
        XCTAssertEqual(tabs.splitRegions, [.main, pane, .side])
        XCTAssertEqual(tabs.main, [.session], "the main row is as it was")
    }

    /// The edge says which side: left of the main row reads first.
    func testTheEdgeSaysWhichSide() {
        var tabs = WorkspaceTabs()
        let left = tabs.split(.main, on: .left, placing: terminal())!
        let under = tabs.split(.main, on: .down, placing: terminal())!
        XCTAssertEqual(tabs.splitRegions, [left, .main, under])
    }

    /// A tab that is already somewhere is moved into the pane, and the row
    /// it left behaves as it does for any move.
    func testSplittingMovesATabThatIsOpen() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .side, at: 0)
        tabs.bringForward(changes)
        tabs.place(fileA, in: .main, at: .max)
        tabs.bringForward(fileA)

        let first = tabs.split(.main, on: .right, placing: changes)
        XCTAssertEqual(tabs.region(of: changes), first)
        XCTAssertTrue(tabs.side.isEmpty)
        XCTAssertFalse(tabs.sideVisible, "the column emptied, so it hid")

        let second = tabs.split(.main, on: .down, placing: fileA)
        XCTAssertEqual(tabs.region(of: fileA), second)
        XCTAssertEqual(tabs.main, [.session])
        XCTAssertNil(tabs.activeMain, "the terminal is in front of the main row again")
        XCTAssertEqual(tabs.allTabs.filter { $0 == changes || $0 == fileA }.count, 2, "each still once")
    }

    /// Splitting a pane puts the new one beside that pane, not the main row.
    func testSplittingAPaneSplitsThatPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let shell = terminal()
        let under = tabs.split(pane, on: .down, placing: shell)!
        XCTAssertEqual(tabs.splitRegions, [.main, pane, under, .side])
        guard case .split(.row, let parts) = tabs.layout.root, parts.count == 3 else {
            return XCTFail("not a row of three: \(tabs.layout.root)")
        }
        XCTAssertEqual(parts[0].node, .leaf(.main))
        XCTAssertEqual(parts[1].node, .split(.column, [.init(node: .leaf(pane.leaf), weight: 0.5),
                                                       .init(node: .leaf(under.leaf), weight: 0.5)]))
        XCTAssertEqual(parts[2].node, .leaf(.side))
        // The main row and the pane share what the main row had. The column
        // keeps its third.
        for part in parts { XCTAssertEqual(part.weight, 1.0 / 3, accuracy: 1e-9) }
    }

    /// A strip with no tabs is no leaf, a column that is hidden takes no
    /// room, and a pane that has gone isn't there: asked about one of those,
    /// the main row is split.
    func testSplittingWhatIsNotALeafSplitsTheMainRow() {
        for region in [TabRegion.side, .bottom, .pane(UUID())] {
            var tabs = column()
            tabs.sideVisible = false
            let shell = terminal()
            guard let pane = tabs.split(region, on: .left, placing: shell) else {
                XCTFail("\(region): nothing was split")
                continue
            }
            XCTAssertEqual(tabs.splitRegions, [pane, .main, .side], "\(region)")
            XCTAssertEqual(tabs.region(of: shell), pane)
        }
    }

    /// A pane's only tab can't be split off its own pane: nothing changes.
    func testSplittingAPaneFromItsOnlyTabIsANoOp() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.toggleZoom(.main)
        let before = tabs
        XCTAssertNil(tabs.split(pane, on: .down, placing: changes))
        XCTAssertEqual(tabs, before, "not even the zoom")

        // With a second tab in the pane there is something to split off.
        tabs.move(history, to: pane, at: .max)
        let under = tabs.split(pane, on: .down, placing: changes)
        XCTAssertNotNil(under)
        XCTAssertEqual(tabs.tabs(in: pane), [history])
        XCTAssertEqual(under.map { tabs.tabs(in: $0) }, [changes])
    }

    /// The session's terminal never leaves the main row.
    func testTheSessionTerminalIsNeverSplitOff() {
        var tabs = column()
        let before = tabs
        XCTAssertNil(tabs.split(.main, on: .right, placing: .session))
        XCTAssertEqual(tabs, before)
    }

    /// An id that is taken makes no second pane of it.
    func testSplittingWithATakenIdChangesNothing() {
        var tabs = column()
        let id = splitOff(changes, from: &tabs).paneID!
        let before = tabs
        XCTAssertNil(tabs.split(.main, on: .down, placing: terminal(), id: id))
        XCTAssertEqual(tabs, before)
    }

    /// The tab can be the last of another pane: that pane goes, and the new
    /// one is still made beside the one asked about.
    func testSplittingWithAnotherPanesLastTab() {
        var tabs = column()
        let first = splitOff(changes, from: &tabs)
        let shell = terminal()
        let second = tabs.split(.main, on: .down, placing: shell)!
        XCTAssertEqual(tabs.splitRegions.count, 4, "the main row, two panes and the column")

        guard let third = tabs.split(second, on: .right, placing: changes) else {
            return XCTFail("nothing was split")
        }
        XCTAssertFalse(tabs.exists(first), "its last tab left, so it went")
        XCTAssertFalse(tabs.layout.contains(first.leaf))
        XCTAssertEqual(tabs.splitRegions, [.main, second, third, .side])
        XCTAssertEqual(tabs.tabs(in: third), [changes])

        // And when the pane asked about is the one that goes, beside the
        // main row: there is nothing else for it to be beside.
        var other = column()
        let pane = splitOff(changes, from: &other)
        guard let moved = other.split(.pane(UUID()), on: .right, placing: changes) else {
            return XCTFail("nothing was split")
        }
        XCTAssertFalse(other.exists(pane))
        XCTAssertEqual(other.splitRegions, [.main, moved, .side])
    }

    /// A new pane is something to look at: a zoom ends.
    func testSplittingEndsAZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.toggleZoom(pane)
        XCTAssertEqual(tabs.zoomed, pane)
        tabs.split(pane, on: .down, placing: terminal())
        XCTAssertNil(tabs.zoomed)
    }

    /// Unless it is a pane you didn't make (`wortel split`): the zoom stays,
    /// on a pane or on the main row, with the new pane behind it, in the
    /// tree and out of sight until the zoom ends.
    func testASplitFromACommandLeavesAZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.toggleZoom(pane)
        let shell = terminal()
        guard let made = tabs.split(.main, on: .down, placing: shell, recordsHabit: false, keepsZoom: true) else {
            return XCTFail("nothing was split")
        }
        XCTAssertEqual(tabs.zoomed, pane)
        XCTAssertEqual(tabs.region(of: shell), made)
        XCTAssertTrue(tabs.layout.contains(made.leaf))
        XCTAssertFalse(tabs.isShowing(made))
        XCTAssertTrue(tabs.isShowing(pane))
        XCTAssertEqual(tabs, tabs.normalized(), "a layout a restart would leave as it is")
        tabs.toggleZoom(pane)
        XCTAssertTrue(tabs.isShowing(made))

        tabs.toggleZoom(.main)
        let second = tabs.split(.main, on: .right, placing: terminal(), recordsHabit: false, keepsZoom: true)
        XCTAssertNotNil(second)
        XCTAssertEqual(tabs.zoomed, .main)
        XCTAssertTrue(tabs.showsSessionTerminal)
    }

    /// A file split off, by a drag or by a command, is in its pane and the
    /// next file still opens where files open.
    func testSplittingAFileOffDoesNotMoveWhereFilesOpen() {
        var tabs = column()
        let pane = tabs.split(.main, on: .right, placing: fileA)!
        XCTAssertEqual(tabs.region(of: fileA), pane)
        XCTAssertTrue(tabs.habits.isEmpty)
        XCTAssertEqual(tabs.home(for: fileB), .main)

        var once = column()
        let other = once.split(.main, on: .right, placing: fileA, recordsHabit: false)
        XCTAssertNotNil(other)
        XCTAssertNil(once.habits[.file])
        XCTAssertEqual(once.home(for: fileB), .main)

        // A terminal has no habit to teach.
        var shells = column()
        shells.split(.main, on: .right, placing: terminal())
        XCTAssertTrue(shells.habits.isEmpty)
    }

    // MARK: A pane lives while it has tabs

    func testTakingOutAPanesLastTabTakesThePaneOut() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        let from = tabs.detach(changes)
        XCTAssertEqual(from?.region, pane)
        XCTAssertEqual(from?.index, 0)
        XCTAssertNil(tabs.panes[id])
        XCTAssertEqual(tabs.layout.leaves, [.main, .side])
        XCTAssertEqual(tabs.layout.share(of: .main, along: .row) ?? 0, 2.0 / 3, accuracy: 1e-9,
                       "its room went back to the main row")
        XCTAssertEqual(tabs.layout.share(of: .side, along: .row) ?? 0, 1.0 / 3, accuracy: 1e-9,
                       "and the column has what it had")
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertFalse(tabs.isShowing(pane))
        XCTAssertNil(tabs.region(of: changes))
    }

    /// With another tab in it the pane stays, the neighbour in front.
    func testTakingOutOneOfSeveralKeepsThePane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        tabs.move(history, to: pane, at: .max)
        tabs.move(files, to: pane, at: .max)
        tabs.bringForward(history)
        tabs.detach(history)
        XCTAssertEqual(tabs.panes[id], WorkspaceTabs.PaneTabs(tabs: [changes, files], active: files))
        XCTAssertTrue(tabs.layout.contains(.pane(id)))
        tabs.detach(files)
        XCTAssertEqual(tabs.front(of: pane), changes, "at the end of the row, the one before")
    }

    /// The room of a pane that went is its siblings', in proportion.
    func testAPaneThatGoesGivesItsRoomToItsSiblings() {
        var tabs = WorkspaceTabs()
        let a = terminal(), b = terminal()
        let first = tabs.split(.main, on: .right, placing: a)!
        let second = tabs.split(first, on: .right, placing: b)!
        // main ½, a ¼, b ¼, as after a drag.
        tabs.layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.5),
            .init(node: .leaf(first.leaf), weight: 0.25),
            .init(node: .leaf(second.leaf), weight: 0.25),
        ]))
        tabs.close(a)
        guard case .split(.row, let parts) = tabs.layout.root else { return XCTFail("not a row of two") }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].weight, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(parts[1].weight, 1.0 / 3, accuracy: 1e-9)
    }

    func testAZoomEndsWhenItsPaneGoes() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let under = tabs.split(.main, on: .down, placing: history)!
        tabs.toggleZoom(pane)
        tabs.detach(changes)
        XCTAssertNil(tabs.zoomed)

        // Zoomed on another pane, it stays.
        tabs.split(.main, on: .right, placing: files)
        tabs.toggleZoom(under)
        tabs.detach(files)
        XCTAssertEqual(tabs.zoomed, under)

        // And a zoom on the main row ends when the main row is all there is
        // on screen: with nothing else, or beside a column that is hidden.
        for hidesColumn in [false, true] {
            var alone = hidesColumn ? column() : WorkspaceTabs()
            alone.sideVisible = false
            let shell = terminal()
            splitOff(shell, from: &alone)
            alone.toggleZoom(.main)
            XCTAssertEqual(alone.zoomed, .main)
            alone.close(shell)
            XCTAssertNil(alone.zoomed, "column hidden: \(hidesColumn)")
        }

        // Beside a column that is showing it stays: there is still
        // something the zoom is hiding.
        var beside = column()
        let shell = terminal()
        splitOff(shell, from: &beside)
        beside.toggleZoom(.main)
        beside.close(shell)
        XCTAssertEqual(beside.zoomed, .main)
    }

    // MARK: Putting a tab in a pane

    func testATabGoesInAPaneOnlyWhileThePaneIsThere() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        XCTAssertTrue(tabs.place(fileA, in: pane, at: 0))
        XCTAssertEqual(tabs.panes[id]?.tabs, [fileA, changes])
        XCTAssertEqual(tabs.front(of: pane), changes, "placing doesn't bring forward")
        XCTAssertEqual(tabs.region(of: fileA), pane)

        let before = tabs
        XCTAssertFalse(tabs.place(fileB, in: .pane(UUID()), at: 0), "split is what makes a pane")
        XCTAssertFalse(tabs.place(.session, in: pane, at: 0))
        XCTAssertFalse(tabs.place(fileA, in: pane, at: 0), "already somewhere")
        XCTAssertEqual(tabs, before)
    }

    func testMovingATabIntoAPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        XCTAssertTrue(tabs.move(history, to: pane, at: 0))
        XCTAssertEqual(tabs.panes[id], WorkspaceTabs.PaneTabs(tabs: [history, changes], active: history))
        XCTAssertEqual(tabs.side, [files])
        XCTAssertEqual(tabs.activeSide, files)
    }

    /// A move to a pane that isn't there leaves the tab where it is.
    func testMovingToAPaneThatHasGoneChangesNothing() {
        var tabs = column()
        splitOff(changes, from: &tabs)
        let before = tabs
        XCTAssertFalse(tabs.move(history, to: .pane(UUID()), at: 0))
        XCTAssertEqual(tabs, before)
        XCTAssertEqual(tabs.region(of: history), .side)
    }

    /// Moving a pane's last tab out is moving the pane away.
    func testMovingAPanesLastTabOutTakesThePane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        XCTAssertTrue(tabs.move(changes, to: .main, at: .max))
        XCTAssertEqual(tabs.main, [.session, changes])
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertFalse(tabs.layout.hasPanes)
        XCTAssertEqual(tabs.splitRegions, [.main, .side])
    }

    /// Between panes, the same: the one it left goes when that was its last.
    func testMovingBetweenPanes() {
        var tabs = column()
        let first = splitOff(changes, from: &tabs)
        let second = tabs.split(.main, on: .down, placing: history)!
        XCTAssertTrue(tabs.move(changes, to: second, at: 0))
        XCTAssertEqual(tabs.tabs(in: second), [changes, history])
        XCTAssertEqual(tabs.front(of: second), changes)
        XCTAssertFalse(tabs.exists(first))
        XCTAssertEqual(tabs.splitRegions, [.main, second, .side])
    }

    /// Reordering in a pane, and the one case that must not take the pane
    /// with it: its only tab dropped back where it is.
    func testReorderingInAPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        let before = tabs
        for index in [0, 1, 5] {
            XCTAssertTrue(tabs.move(changes, to: pane, at: index))
            XCTAssertEqual(tabs, before, "dropped at \(index)")
        }
        tabs.move(history, to: pane, at: .max)
        tabs.move(files, to: pane, at: .max)
        XCTAssertTrue(tabs.move(changes, to: pane, at: 3))
        XCTAssertEqual(tabs.panes[id]?.tabs, [history, files, changes])
        XCTAssertTrue(tabs.move(files, to: pane, at: 0))
        XCTAssertEqual(tabs.panes[id]?.tabs, [files, history, changes])
        XCTAssertEqual(tabs.front(of: pane), files)
    }

    func testMovingIntoAPaneDoesNotMoveWhereItsKindOpens() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: .main, at: .max)
        tabs.move(fileA, to: pane, at: .max)
        XCTAssertEqual(tabs.region(of: fileA), pane)
        XCTAssertEqual(tabs.home(for: fileB), .main)
    }

    // MARK: In front, and the zoom

    func testBringingForwardInAPaneSetsItsFront() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        let id = pane.paneID!
        tabs.place(fileA, in: pane, at: .max)
        XCTAssertEqual(tabs.front(of: pane), changes)
        let side = tabs.activeSide
        tabs.bringForward(fileA)
        XCTAssertEqual(tabs.panes[id]?.active, fileA)
        XCTAssertEqual(tabs.front(of: pane), fileA)
        XCTAssertNil(tabs.activeMain, "the other rows are as they were")
        XCTAssertEqual(tabs.activeSide, side)
        tabs.bringForward(changes)
        XCTAssertEqual(tabs.front(of: pane), changes)
    }

    /// A pane with nothing marked in front shows its first tab.
    func testAPanesFrontDefaultsToItsFirstTab() {
        var tabs = WorkspaceTabs()
        let id = UUID()
        tabs.panes[id] = WorkspaceTabs.PaneTabs(tabs: [changes, history], active: nil)
        tabs.layout.insert(.pane(id), beside: .main, on: .right)
        XCTAssertEqual(tabs.front(of: .pane(id)), changes)
        XCTAssertNil(tabs.front(of: .pane(UUID())), "a pane that isn't there has no front")
        XCTAssertEqual(tabs.tabs(in: .pane(UUID())), [])
    }

    func testZoomShowsOneLeafAlone() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.toggleZoom(pane)
        XCTAssertEqual(tabs.zoomed, pane)
        XCTAssertTrue(tabs.isShowing(pane))
        XCTAssertFalse(tabs.isShowing(.main))
        tabs.toggleZoom(pane)
        XCTAssertNil(tabs.zoomed)
        XCTAssertTrue(tabs.isShowing(.main))

        tabs.toggleZoom(.main)
        XCTAssertEqual(tabs.zoomed, .main)
        XCTAssertTrue(tabs.isShowing(.main))
        XCTAssertFalse(tabs.isShowing(pane))
        // Zooming another leaf moves the zoom there.
        tabs.toggleZoom(pane)
        XCTAssertEqual(tabs.zoomed, pane)
    }

    /// Only a leaf of the tree that is on screen, and only while more than
    /// one is.
    func testOnlyALeafOfASplitAreaZooms() {
        var unsplit = WorkspaceTabs()
        unsplit.toggleZoom(.main)
        XCTAssertNil(unsplit.zoomed, "nothing to zoom out of")

        // A column that is hidden is nothing to zoom out of either, and
        // can't be shown alone.
        var hidden = column()
        hidden.sideVisible = false
        hidden.toggleZoom(.main)
        XCTAssertNil(hidden.zoomed, "the main row is all there is on screen")
        hidden.toggleZoom(.side)
        XCTAssertNil(hidden.zoomed, "a hidden column")

        var tabs = column()
        splitOff(changes, from: &tabs)
        // A strip with no tabs is no leaf, and neither is a pane that has gone.
        for region in [TabRegion.bottom, .pane(UUID())] {
            tabs.toggleZoom(region)
            XCTAssertNil(tabs.zoomed, "\(region)")
        }
    }

    /// The column and the strip are leaves like any other: one of them can
    /// be the leaf shown alone, beside nothing but the main row too.
    func testTheColumnAndTheStripZoom() {
        var tabs = column()
        tabs.toggleZoom(.side)
        XCTAssertEqual(tabs.zoomed, .side)
        XCTAssertTrue(tabs.isShowing(.side))
        XCTAssertFalse(tabs.isShowing(.main))
        XCTAssertFalse(tabs.showsSessionTerminal, "the session's terminal is behind the column")
        tabs.toggleZoom(.side)
        XCTAssertNil(tabs.zoomed)
        XCTAssertTrue(tabs.showsSessionTerminal)

        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.bringForward(shell)
        tabs.toggleZoom(.bottom)
        XCTAssertEqual(tabs.zoomed, .bottom)
        XCTAssertTrue(tabs.isShowing(.bottom))
        XCTAssertFalse(tabs.isShowing(.side))
        XCTAssertFalse(tabs.showsSessionTerminal)

        // The main row zooms over a column, with no pane anywhere.
        var plain = column()
        plain.toggleZoom(.main)
        XCTAssertEqual(plain.zoomed, .main)
        XCTAssertFalse(plain.isShowing(.side))
    }

    /// A zoom hides the column and the strip as it hides every other leaf.
    /// (It left them alone while they were beside the tree, not in it.)
    func testAZoomHidesTheColumnAndTheStripToo() {
        var tabs = column()
        let pane = splitOff(terminal(), from: &tabs)
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        XCTAssertTrue(tabs.isShowing(.side))
        XCTAssertTrue(tabs.isShowing(.bottom), "on screen from the moment it holds a tab")
        tabs.bringForward(shell)
        XCTAssertTrue(tabs.isShowing(.bottom))

        tabs.toggleZoom(pane)
        XCTAssertFalse(tabs.isShowing(.side))
        XCTAssertFalse(tabs.isShowing(.bottom))
        XCTAssertTrue(tabs.sideVisible && tabs.bottomVisible, "behind the zoom, not hidden: they are back with it")
        tabs.toggleZoom(pane)
        XCTAssertTrue(tabs.isShowing(.side))
        XCTAssertTrue(tabs.isShowing(.bottom))
    }

    /// Bringing a tab forward in a leaf the zoom hides ends the zoom: it
    /// would have come forward out of sight.
    func testBringingForwardInAnotherLeafEndsTheZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: .main, at: .max)
        tabs.toggleZoom(pane)
        tabs.bringForward(fileA)
        XCTAssertNil(tabs.zoomed)

        tabs.toggleZoom(.main)
        tabs.bringForward(changes)
        XCTAssertNil(tabs.zoomed)
    }

    /// In the zoomed leaf itself it stays. In the column or the strip it
    /// ends, as in any other leaf: they are under the zoom now, and the tab
    /// would have come forward out of sight.
    func testBringingForwardInTheColumnOrTheStripEndsTheZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: pane, at: .max)
        tabs.place(fileB, in: pane, at: .max)
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.toggleZoom(pane)

        tabs.bringForward(fileA)
        XCTAssertEqual(tabs.zoomed, pane, "a tab of the zoomed pane")
        tabs.bringForward(opened: fileB)
        XCTAssertEqual(tabs.zoomed, pane)

        tabs.bringForward(history)
        XCTAssertNil(tabs.zoomed, "the column is a leaf the zoom was hiding")
        XCTAssertTrue(tabs.isShowing(.side))

        tabs.toggleZoom(pane)
        tabs.bringForward(shell)
        XCTAssertNil(tabs.zoomed, "and so is the strip")
        XCTAssertTrue(tabs.isShowing(.bottom), "brought forward there, it shows, as it always did")

        tabs.toggleZoom(pane)
        tabs.bringForward(opened: files)
        XCTAssertNil(tabs.zoomed)

        // Zoomed on the column itself, a tab of the column keeps it.
        tabs.toggleZoom(.side)
        tabs.bringForward(history)
        XCTAssertEqual(tabs.zoomed, .side)
    }

    /// A file opened into a hidden leaf ends the zoom too: opening is
    /// bringing forward.
    func testOpeningIntoAHiddenLeafEndsTheZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.toggleZoom(pane)
        tabs.place(fileA, in: .main, at: .max)
        XCTAssertEqual(tabs.zoomed, pane, "placing alone shows nothing")
        tabs.bringForward(opened: fileA)
        XCTAssertNil(tabs.zoomed)
    }

    /// The session's terminal isn't on screen while a pane is zoomed over it.
    func testTheTerminalIsNotShownUnderAZoomedPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        XCTAssertTrue(tabs.showsSessionTerminal)
        tabs.toggleZoom(pane)
        XCTAssertFalse(tabs.showsSessionTerminal)
        tabs.toggleZoom(.main)
        XCTAssertTrue(tabs.showsSessionTerminal, "zoomed itself, it is all there is")
        tabs.toggleZoom(.main)
        XCTAssertTrue(tabs.showsSessionTerminal)
    }

    /// A split asked of a leaf too small to be two takes its room from the
    /// whole row (`spreads`); where the leaf has no such row it is halved.
    func testASplitThatSpreadsTakesFromTheRow() {
        var tabs = WorkspaceTabs()
        let first = tabs.split(.main, on: .right, placing: terminal())!
        tabs.layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.8), .init(node: .leaf(first.leaf), weight: 0.2),
        ]))
        let second = tabs.split(first, on: .right, placing: terminal(), spreads: true)!
        guard case .split(.row, let parts) = tabs.layout.root else { return XCTFail("not a row") }
        XCTAssertEqual(parts.map(\.node), [.leaf(.main), .leaf(first.leaf), .leaf(second.leaf)])
        XCTAssertEqual(parts[2].weight, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(parts[1].weight, 0.2 * 2 / 3, accuracy: 1e-9)

        // Down from a leaf of a row: no column to take from, so it is halved.
        let third = tabs.split(second, on: .down, placing: terminal(), spreads: true)!
        XCTAssertTrue(tabs.layout.contains(third.leaf))
        XCTAssertEqual(tabs.layout.share(of: third.leaf, along: .column) ?? 0, 0.5, accuracy: 1e-9)
    }

    func testEqualizeEvensTheLayout() {
        var tabs = WorkspaceTabs()
        let first = tabs.split(.main, on: .right, placing: terminal())!
        let second = tabs.split(first, on: .right, placing: terminal())!
        XCTAssertTrue(tabs.layout.isEqualized, "three splits among equals are thirds")
        tabs.layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.5),
            .init(node: .leaf(first.leaf), weight: 0.25),
            .init(node: .leaf(second.leaf), weight: 0.25),
        ]))
        XCTAssertFalse(tabs.layout.isEqualized)
        let leaves = tabs.layout.leaves
        tabs.equalize()
        XCTAssertTrue(tabs.layout.isEqualized)
        XCTAssertEqual(tabs.layout.leaves, leaves)
    }

    // MARK: Where things open

    /// Where a kind opens is the same with one of it in a pane, and after
    /// that pane has gone.
    func testWhereAKindOpensDoesNotFollowAPane() {
        var tabs = column()
        let pane = tabs.split(.main, on: .right, placing: fileA)!
        let browser = SideTab.browser(UUID())
        tabs.placeDropped(browser, in: pane, at: .max)
        XCTAssertEqual(tabs.home(for: fileB), .main)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)

        tabs.close(fileA)
        tabs.close(browser)
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertEqual(tabs.home(for: fileB), .main)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)
    }

    /// ⌥ sends a tab out of the main row, and anything else into it: a tab
    /// in a pane, or one that would open in one, goes to the main row.
    func testElsewhereFromAPaneIsTheMainRow() {
        var tabs = column()
        let pane = tabs.split(.main, on: .right, placing: fileA)!
        XCTAssertEqual(tabs.elsewhere(for: fileA), .main)
        XCTAssertEqual(tabs.elsewhere(for: fileB), .side, "it would open in the main row")
        tabs.place(fileC, in: .main, at: .max)
        XCTAssertEqual(tabs.elsewhere(for: fileC), .side)
        tabs.close(fileA)
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertEqual(tabs.elsewhere(for: fileB), .side, "back to opening in the main row")
    }

    /// A drop into a pane that has gone opens nothing.
    func testDroppingIntoAPaneThatHasGone() {
        var tabs = column()
        let before = tabs
        tabs.placeDropped(fileA, in: .pane(UUID()), at: 0)
        XCTAssertEqual(tabs, before)
    }

    // MARK: Closing and reopening in a pane

    func testClosingInAPaneRemembersThePane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: pane, at: .max)
        XCTAssertEqual(tabs.close(fileA), pane)
        XCTAssertEqual(tabs.closed.last, ClosedTab(tab: fileA, region: pane, index: 1))
        XCTAssertTrue(tabs.exists(pane))

        XCTAssertEqual(tabs.reopen(preferring: .main), fileA, "the only one closed")
        XCTAssertEqual(tabs.tabs(in: pane), [changes, fileA], "back in its pane, in its place")
        XCTAssertEqual(tabs.front(of: pane), fileA)
    }

    /// Reopening prefers what was closed in the pane you're in.
    func testReopeningPrefersThePaneYouAreIn() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: pane, at: .max)
        tabs.close(fileA)
        tabs.close(history)
        XCTAssertEqual(tabs.reopen(preferring: pane), fileA)
        XCTAssertEqual(tabs.region(of: fileA), pane)
        XCTAssertEqual(tabs.reopen(preferring: pane), history, "then the last closed anywhere")
        XCTAssertEqual(tabs.region(of: history), .side)
    }

    /// The opener rule holds in a pane: a file opened from Changes there
    /// goes back to Changes.
    func testClosingInAPaneGoesBackToWhereItWasOpenedFrom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileC, in: pane, at: .max)
        tabs.bringForward(changes)
        tabs.place(fileA, in: pane, at: .max)
        tabs.bringForward(opened: fileA)
        XCTAssertEqual(tabs.tabs(in: pane), [changes, fileC, fileA])
        tabs.close(fileA)
        XCTAssertEqual(tabs.front(of: pane), changes, "not its neighbour")

        // Left in between, it is the neighbour rule's again.
        tabs.place(fileB, in: pane, at: 1)
        tabs.bringForward(opened: fileB)
        tabs.bringForward(fileC)
        tabs.bringForward(fileB)
        tabs.close(fileB)
        XCTAssertEqual(tabs.front(of: pane), fileC)
    }

    /// Closing a pane's last tab is closing the pane.
    func testClosingAPanesLastTabClosesThePane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        XCTAssertEqual(tabs.close(changes), pane)
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertFalse(tabs.layout.hasPanes)
        XCTAssertEqual(tabs.closed.last?.region, pane, "where it was, though that has gone")
    }

    /// A tab closed in a pane that has gone comes back in the row you're in.
    func testReopeningFromAPaneThatHasGoneUsesTheRowYouAreIn() {
        for preferred in [TabRegion.side, .bottom, .main] {
            var tabs = column()
            let pane = splitOff(fileA, from: &tabs)
            tabs.close(fileA)
            XCTAssertFalse(tabs.exists(pane))
            XCTAssertEqual(tabs.reopen(preferring: preferred), fileA)
            XCTAssertEqual(tabs.region(of: fileA), preferred, "\(preferred)")
            XCTAssertEqual(tabs.front(of: preferred), fileA)
            XCTAssertEqual(tabs.tabs(in: preferred).last, fileA, "at the end: its old index was another row's")
            XCTAssertTrue(tabs.isShowing(preferred))
        }
    }

    /// In another pane, when that is where you are.
    func testReopeningFromAPaneThatHasGoneIntoAnotherPane() {
        var tabs = column()
        let pane = splitOff(fileA, from: &tabs)
        let other = tabs.split(.main, on: .down, placing: history)!
        tabs.close(fileA)
        XCTAssertFalse(tabs.exists(pane))
        XCTAssertEqual(tabs.reopen(preferring: other), fileA)
        XCTAssertEqual(tabs.tabs(in: other), [history, fileA])
    }

    /// And in the main row when the row you were in has gone too.
    func testReopeningWhenBothPanesHaveGoneUsesTheMainRow() {
        var tabs = column()
        let pane = splitOff(fileA, from: &tabs)
        tabs.close(fileA)
        XCTAssertEqual(tabs.reopen(preferring: pane), fileA)
        XCTAssertEqual(tabs.main, [.session, fileA])
        XCTAssertEqual(tabs.activeMain, fileA)
        XCTAssertFalse(tabs.layout.hasPanes, "reopening a tab doesn't remake its pane")
    }

    /// A terminal reopened this way is a new shell, in the main row.
    func testATerminalReopenedFromAPaneThatHasGone() {
        let shell = terminal()
        var tabs = column()
        let pane = splitOff(shell, from: &tabs)
        tabs.close(shell)
        let reopened = tabs.reopen(preferring: pane)
        XCTAssertNotNil(reopened?.terminalID)
        XCTAssertNotEqual(reopened, shell, "its shell ended with it")
        XCTAssertEqual(tabs.main.first, .session)
        XCTAssertEqual(tabs.main.last, reopened)
        XCTAssertEqual(tabs.main.count, 2)
        XCTAssertTrue(tabs.closed.isEmpty)
    }

    /// `takeClosed` answers with a row that is there, for whoever places it.
    func testTakeClosedNamesARowThatIsThere() {
        var tabs = column()
        let pane = splitOff(fileA, from: &tabs)
        tabs.place(fileB, in: pane, at: .max)
        tabs.close(fileB)
        XCTAssertEqual(tabs.takeClosed(preferring: .side), ClosedTab(tab: fileB, region: pane, index: 1),
                       "its pane is still there")
        tabs.close(fileA)
        XCTAssertEqual(tabs.takeClosed(preferring: .side)?.region, .side)
        XCTAssertNil(tabs.takeClosed(preferring: .side))
    }

    // MARK: The preview tab in a pane

    /// A preview shown in a pane, and the next file takes its place in
    /// that pane's row: it follows the preview tab, wherever that is.
    func testThePreviewSwapsInPlaceInAPane() {
        var tabs = column()
        let pane = splitOff(a, from: &tabs)
        let id = pane.paneID!
        tabs.place(terminal(), in: pane, at: .max)
        XCTAssertEqual(tabs.peekRegion(for: b, avoiding: .side), .main, "where files open")

        XCTAssertNil(tabs.showPeek(b, in: pane))
        XCTAssertEqual(tabs.peek, b)
        XCTAssertEqual(tabs.front(of: pane), b)
        let index = tabs.panes[id]?.tabs.firstIndex(of: b)
        XCTAssertEqual(index, 2)

        XCTAssertEqual(tabs.showPeek(c, in: pane), b, "the file it replaced")
        XCTAssertEqual(tabs.panes[id]?.tabs.firstIndex(of: c), index, "in its place")
        XCTAssertEqual(tabs.panes[id]?.active, c)
        XCTAssertNil(tabs.region(of: b))
        XCTAssertEqual(tabs.peekInFront, c)

        // Closing it goes back to what was in front before the first.
        tabs.close(c)
        XCTAssertEqual(tabs.front(of: pane), a)
        XCTAssertNil(tabs.peek)
    }

    /// A list in a pane never has its own row taken by what it picks.
    func testThePreviewAvoidsAListInAPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: pane), .main)
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: .side), .main)
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: .main), .side, "not over the list")
        // The preview tab's own row, wherever it is.
        tabs.showPeek(a, in: pane)
        XCTAssertEqual(tabs.peekRegion(for: b, avoiding: .side), pane)
        XCTAssertEqual(tabs.peekRegion(for: b, avoiding: pane), .main)
    }

    /// A click follows in a pane while a file is in front of it, and the
    /// pane is on screen.
    func testShowsFileInAPane() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        XCTAssertFalse(tabs.showsFile(in: pane))
        tabs.showPeek(a, in: pane)
        XCTAssertTrue(tabs.showsFile(in: pane))
        XCTAssertEqual(tabs.peekInFront, a)
        XCTAssertEqual(tabs.peekAction(for: b, .follow, avoiding: .side), .show)

        tabs.toggleZoom(.main)
        XCTAssertFalse(tabs.showsFile(in: pane), "behind a zoom nothing is in front of anything")
        XCTAssertNil(tabs.peekInFront)
        tabs.toggleZoom(.main)

        tabs.bringForward(changes)
        XCTAssertFalse(tabs.showsFile(in: pane))
        XCTAssertNil(tabs.peekInFront)
        XCTAssertFalse(tabs.showsFile(in: .pane(UUID())))
    }

    /// The main row's file isn't in front while a pane is zoomed over it.
    func testShowsFileInTheMainRowNeedsItOnScreen() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.showPeek(a, in: .main)
        XCTAssertTrue(tabs.showsFile(in: .main))
        tabs.toggleZoom(pane)
        XCTAssertFalse(tabs.showsFile(in: .main))
    }

    /// The preview that is a pane's only tab: taking it out by moving it
    /// keeps it, as any move does.
    func testMovingThePreviewOutOfAPaneKeepsIt() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.showPeek(a, in: pane)
        tabs.move(a, to: .main, at: .max)
        XCTAssertNil(tabs.peek)
        XCTAssertTrue(tabs.exists(pane), "changes is still in it")
    }

    // MARK: Every tab

    func testEveryTabIsCountedInReadingOrder() {
        var tabs = column()
        let strip = terminal(), right = terminal(), left = terminal()
        tabs.place(strip, in: .bottom, at: 0)
        let rightPane = tabs.split(.main, on: .right, placing: right)!
        tabs.place(fileA, in: rightPane, at: .max)
        let leftPane = tabs.split(.main, on: .left, placing: left)!
        XCTAssertEqual(tabs.splitRegions, [leftPane, .main, rightPane, .bottom, .side],
                       "the strip under the main row's part, the column past everything")
        XCTAssertEqual(tabs.allTabs, [.session, changes, history, files, strip, left, right, fileA])
        XCTAssertEqual(Set(tabs.terminalIDs), Set([strip, right, left].compactMap(\.terminalID)))
    }

    /// A pane the layout has lost track of still has its terminals counted:
    /// one left out is a shell nobody closes.
    func testTerminalsOfAStrayPaneStillCount() {
        var tabs = WorkspaceTabs()
        let shell = terminal()
        tabs.panes[UUID()] = WorkspaceTabs.PaneTabs(tabs: [shell], active: shell)
        XCTAssertEqual(tabs.terminalIDs, [shell].compactMap(\.terminalID))
        XCTAssertEqual(tabs.allTabs, [.session, shell])
    }

    func testAnUnsplitWorkspaceHasNoPanes() {
        let tabs = column()
        XCTAssertEqual(tabs.splitRegions, [.main, .side], "the column is a leaf, and no pane")
        XCTAssertTrue(tabs.panes.isEmpty)
        XCTAssertFalse(tabs.layout.hasPanes)
        XCTAssertFalse(WorkspaceTabs().layout.isSplit)
        XCTAssertNil(tabs.zoomed)
        XCTAssertTrue(tabs.isShowing(.main))
        XCTAssertTrue(tabs.exists(.main) && tabs.exists(.side) && tabs.exists(.bottom))
        XCTAssertEqual(tabs.normalized(), tabs)
    }

    // MARK: Consistency with panes

    /// A consistent layout is left as it is.
    func testNormalizedLeavesGoodPanesAlone() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: pane, at: .max)
        tabs.split(pane, on: .down, placing: terminal())
        tabs.habits[.file] = pane
        tabs.toggleZoom(pane)
        XCTAssertEqual(tabs.normalized(), tabs)
    }

    /// A tab two rows claim stays in the first: main, column, strip, then
    /// the panes as the layout reads.
    func testATabInTwoRowsStaysInTheFirst() {
        let left = UUID(), right = UUID()
        var tabs = WorkspaceTabs(main: [.session, fileA], side: [changes, fileB], sideVisible: true,
                                 bottom: [fileC])
        tabs.panes[left] = WorkspaceTabs.PaneTabs(tabs: [fileA, history, a], active: history)
        tabs.panes[right] = WorkspaceTabs.PaneTabs(tabs: [fileB, fileC, a, b], active: a)
        tabs.layout.insert(.pane(right), beside: .main, on: .right)
        tabs.layout.insert(.pane(left), beside: .main, on: .left)

        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.main, [.session, fileA])
        XCTAssertEqual(fixed.side, [changes, fileB])
        XCTAssertEqual(fixed.bottom, [fileC])
        XCTAssertEqual(fixed.panes[left]?.tabs, [history, a], "the left pane reads first")
        XCTAssertEqual(fixed.panes[right], WorkspaceTabs.PaneTabs(tabs: [b], active: b),
                       "and its front is something it still has")
        XCTAssertEqual(fixed.allTabs.count, Set(fixed.allTabs).count)
    }

    /// The session's terminal is the main row's, whatever a pane says.
    func testTheSessionTerminalIsNeverInAPane() {
        let id = UUID()
        var tabs = WorkspaceTabs(main: [fileA])
        tabs.panes[id] = WorkspaceTabs.PaneTabs(tabs: [.session, changes], active: .session)
        tabs.layout.insert(.pane(id), beside: .main, on: .right)
        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.main, [.session, fileA])
        XCTAssertEqual(fixed.panes[id], WorkspaceTabs.PaneTabs(tabs: [changes], active: changes))

        // With nothing else in it, the pane goes.
        tabs.panes[id] = WorkspaceTabs.PaneTabs(tabs: [.session], active: .session)
        let emptied = tabs.normalized()
        XCTAssertTrue(emptied.panes.isEmpty)
        XCTAssertFalse(emptied.layout.isSplit)
    }

    /// A pane with no tabs, and a leaf with no pane, are both dropped.
    func testEmptyPanesAndLeavesWithoutOneAreDropped() {
        let empty = UUID(), ghost = UUID(), real = UUID()
        var tabs = WorkspaceTabs()
        tabs.panes[empty] = WorkspaceTabs.PaneTabs(tabs: [], active: nil)
        tabs.panes[real] = WorkspaceTabs.PaneTabs(tabs: [changes], active: changes)
        for id in [empty, ghost, real] { tabs.layout.insert(.pane(id), beside: .main, on: .right) }

        let fixed = tabs.normalized()
        XCTAssertEqual(Array(fixed.panes.keys), [real])
        XCTAssertEqual(fixed.layout.leaves, [.main, .pane(real)])
        guard case .split(.row, let parts) = fixed.layout.root else { return XCTFail("not split") }
        XCTAssertEqual(parts.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
    }

    /// A pane the layout doesn't know (the tree couldn't be read): its tabs
    /// go to the main row. A terminal is never lost for want of a place.
    func testAPaneMissingFromTheLayoutFoldsIntoTheMainRow() {
        let shell = terminal()
        var tabs = WorkspaceTabs(main: [.session, fileA], activeMain: fileA)
        tabs.panes[UUID()] = WorkspaceTabs.PaneTabs(tabs: [shell, fileA, changes, .session], active: shell)

        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.main, [.session, fileA, shell, changes], "after what the row had, each once")
        XCTAssertEqual(fixed.activeMain, fileA, "what was in front still is")
        XCTAssertTrue(fixed.panes.isEmpty)
        XCTAssertFalse(fixed.layout.isSplit)
        XCTAssertEqual(fixed.terminalIDs, [shell].compactMap(\.terminalID))
    }

    /// The tree itself is put right too: a leaf twice, weights that are no
    /// shares, the main row missing.
    func testTheLayoutIsNormalized() {
        let id = UUID()
        var tabs = WorkspaceTabs()
        tabs.panes[id] = WorkspaceTabs.PaneTabs(tabs: [changes], active: changes)
        tabs.layout = SplitLayout(root: .split(.column, [
            .init(node: .leaf(.pane(id)), weight: 3),
            .init(node: .leaf(.pane(id)), weight: 1),
        ]))
        let fixed = tabs.normalized()
        XCTAssertEqual(Set(fixed.layout.leaves), [.main, .pane(id)])
        XCTAssertEqual(fixed.layout, fixed.layout.normalized())
        XCTAssertEqual(fixed.panes[id]?.tabs, [changes])
    }

    func testAPanesFrontIsSomethingItHas() {
        let first = UUID(), second = UUID()
        var tabs = WorkspaceTabs()
        tabs.panes[first] = WorkspaceTabs.PaneTabs(tabs: [changes, history], active: files)
        tabs.panes[second] = WorkspaceTabs.PaneTabs(tabs: [fileA, fileB], active: nil)
        tabs.layout.insert(.pane(first), beside: .main, on: .right)
        tabs.layout.insert(.pane(second), beside: .main, on: .down)
        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.panes[first]?.active, changes)
        XCTAssertEqual(fixed.panes[second]?.active, fileA)
    }

    /// A zoom on something that isn't a leaf on screen is no zoom.
    func testAZoomIsOnALeafThatIsThere() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        // A strip with no tabs, and a pane that has gone.
        for zoomed in [TabRegion.bottom, .pane(UUID())] {
            tabs.zoomed = zoomed
            XCTAssertNil(tabs.normalized().zoomed, "\(zoomed)")
        }
        for zoomed in [pane, .main, .side] {
            tabs.zoomed = zoomed
            XCTAssertEqual(tabs.normalized().zoomed, zoomed, "\(zoomed)")
        }
        // A column that is hidden can't be the one shown alone.
        tabs.sideVisible = false
        tabs.zoomed = .side
        XCTAssertNil(tabs.normalized().zoomed)

        var unsplit = WorkspaceTabs()
        unsplit.zoomed = .main
        XCTAssertNil(unsplit.normalized().zoomed, "there is nothing to zoom out of")
        var hidden = column()
        hidden.sideVisible = false
        hidden.zoomed = .main
        XCTAssertNil(hidden.normalized().zoomed, "nor beside a column that is hidden")
    }

    /// A habit and a preview that point at what has gone are dropped.
    func testHabitsForPanesThatHaveGoneAreDropped() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.habits = [.file: .pane(UUID()), .browser: pane]
        XCTAssertEqual(tabs.normalized().habits, [.browser: pane])
        tabs.peek = fileA
        XCTAssertNil(tabs.normalized().peek)
        tabs.place(fileA, in: pane, at: .max)
        XCTAssertEqual(tabs.normalized().peek, fileA, "a preview in a pane is a preview")
    }

    // MARK: - The column and the strip are leaves

    private let area = CGRect(x: 0, y: 0, width: 1202, height: 600)

    private func share(of leaf: SplitLayout.Leaf, along axis: SplitLayout.Axis, in tabs: WorkspaceTabs) -> Double {
        tabs.layout.share(of: leaf, along: axis) ?? -1
    }

    /// A file from a build that could hide the column or the strip with its
    /// tabs kept: the panes of a hidden one are closed, and anything else
    /// in it is on screen, because nothing is hidden any more and a shell
    /// must not be out of reach.
    func testWhatAnOlderBuildHidComesBackOrCloses() {
        // A hidden column of panes only: closed, and its leaf with it.
        var panesOnly = WorkspaceTabs(side: [changes, files], activeSide: changes, sideVisible: false)
        panesOnly.showHidden()
        XCTAssertTrue(panesOnly.side.isEmpty)
        XCTAssertFalse(panesOnly.layout.contains(.side))
        XCTAssertFalse(panesOnly.isShowing(.side))

        // A hidden column with a terminal among them: the panes closed, the
        // terminal on screen.
        let shell = terminal()
        var mixed = WorkspaceTabs(side: [changes, shell], activeSide: changes, sideVisible: false)
        mixed.showHidden()
        XCTAssertEqual(mixed.side, [shell])
        XCTAssertEqual(mixed.front(of: .side), shell)
        XCTAssertTrue(mixed.isShowing(.side))
        XCTAssertTrue(mixed.hiddenLeaves.isEmpty)

        // A hidden strip with a shell in it: on screen.
        let log = terminal()
        var strip = WorkspaceTabs(bottom: [log], activeBottom: log, bottomVisible: false)
        strip.showHidden()
        XCTAssertEqual(strip.bottom, [log])
        XCTAssertTrue(strip.isShowing(.bottom))

        // What was showing is left as it is.
        var showing = WorkspaceTabs(side: [changes, files], activeSide: files, sideVisible: true)
        showing.showHidden()
        XCTAssertEqual(showing.side, [changes, files])
        XCTAssertEqual(showing.front(of: .side), files)
    }

    /// The column is a leaf of the tree exactly while it has tabs: made by
    /// its first, at the outer edge with a third of the width, and gone with
    /// its last. Showing or hidden makes no difference to that.
    func testTheColumnIsALeafWhileItHasTabs() {
        var tabs = WorkspaceTabs()
        XCTAssertEqual(tabs.layout, SplitLayout())
        XCTAssertTrue(tabs.place(changes, in: .side, at: 0))
        XCTAssertEqual(tabs.layout.leaves, [.main, .side])
        XCTAssertEqual(share(of: .side, along: .row, in: tabs), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(tabs.unsized, [.side], "a guess, until the window has laid it out")
        XCTAssertTrue(tabs.hiddenLeaves.isEmpty, "on screen from the moment it holds a tab")
        XCTAssertTrue(tabs.isShowing(.side))

        tabs.bringForward(changes)
        XCTAssertTrue(tabs.hiddenLeaves.isEmpty)
        XCTAssertTrue(tabs.isShowing(.side))

        let one = tabs.layout
        tabs.place(history, in: .side, at: .max)
        XCTAssertEqual(tabs.layout, one, "one more tab is the same leaf")
        tabs.close(history)
        XCTAssertEqual(tabs.layout, one)

        tabs.close(changes)
        XCTAssertEqual(tabs.layout, SplitLayout(), "its last tab took it out")
        XCTAssertTrue(tabs.unsized.isEmpty)
        XCTAssertTrue(tabs.hiddenLeaves.isEmpty)
        XCTAssertFalse(tabs.sideVisible)
    }

    func testTheColumnOpensOnItsSide() {
        var trailing = WorkspaceTabs()
        trailing.place(changes, in: .side, at: 0)
        XCTAssertEqual(trailing.splitRegions, [.main, .side])

        var leading = WorkspaceTabs(sideLeading: true)
        leading.place(changes, in: .side, at: 0)
        XCTAssertEqual(leading.splitRegions, [.side, .main])
    }

    /// The strip opens directly under the main row, wherever the main row
    /// is, with three tenths of its height.
    func testTheStripOpensUnderTheMainRow() {
        var tabs = column()
        let pane = splitOff(terminal(), from: &tabs)
        let shell = terminal()
        XCTAssertTrue(tabs.place(shell, in: .bottom, at: 0))
        XCTAssertEqual(tabs.splitRegions, [.main, .bottom, pane, .side])
        XCTAssertEqual(share(of: .bottom, along: .column, in: tabs), 0.3, accuracy: 1e-9)
        XCTAssertEqual(share(of: .main, along: .column, in: tabs), 0.7, accuracy: 1e-9)
        XCTAssertEqual(share(of: .bottom, along: .row, in: tabs), share(of: .main, along: .row, in: tabs),
                       accuracy: 1e-9, "as wide as the main row, not the whole area")
        XCTAssertEqual(share(of: pane.leaf, along: .column, in: tabs), 1, accuracy: 1e-9)
        XCTAssertTrue(tabs.unsized.contains(.bottom))
        XCTAssertFalse(tabs.hiddenLeaves.contains(.bottom), "on screen from the moment it holds a tab")

        tabs.detach(shell)
        XCTAssertEqual(tabs.splitRegions, [.main, pane, .side])
        XCTAssertEqual(share(of: .main, along: .column, in: tabs), 1, accuracy: 1e-9)
        XCTAssertFalse(tabs.unsized.contains(.bottom))
    }

    /// The column takes the outer edge of the whole area, strip and all,
    /// whichever of the two came first, and however the tabs got there.
    func testTheColumnIsAtTheOuterEdgeOfEverything() {
        let shell = terminal()
        var tabs = WorkspaceTabs()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.place(changes, in: .side, at: 0)
        XCTAssertEqual(tabs.splitRegions, [.main, .bottom, .side])
        XCTAssertEqual(share(of: .side, along: .column, in: tabs), 1, accuracy: 1e-9)
        XCTAssertEqual(share(of: .side, along: .row, in: tabs), 1.0 / 3, accuracy: 1e-9)

        var other = WorkspaceTabs()
        other.place(changes, in: .side, at: 0)
        other.place(shell, in: .bottom, at: 0)
        XCTAssertEqual(other.layout, tabs.layout)

        // Made with tabs already in its rows, it has their leaves.
        let made = WorkspaceTabs(side: [changes], activeSide: changes, bottom: [shell], activeBottom: shell)
        XCTAssertEqual(made.layout, tabs.layout)
        XCTAssertEqual(made.unsized, [.side, .bottom])
        XCTAssertEqual(made.normalized(), made)
    }

    /// Every way a tab gets into the column or the strip makes the leaf.
    func testEveryWayIntoTheColumnOrTheStripMakesItsLeaf() {
        var moved = WorkspaceTabs()
        moved.place(fileA, in: .main, at: .max)
        moved.move(fileA, to: .side, at: 0)
        XCTAssertEqual(moved.splitRegions, [.main, .side])
        XCTAssertTrue(moved.isShowing(.side))

        var dropped = WorkspaceTabs()
        dropped.placeDropped(fileA, in: .bottom, at: 0)
        XCTAssertEqual(dropped.splitRegions, [.main, .bottom])
        XCTAssertTrue(dropped.isShowing(.bottom))

        var peeked = WorkspaceTabs()
        peeked.showPeek(fileA, in: .side)
        XCTAssertEqual(peeked.splitRegions, [.main, .side])

        var reopened = WorkspaceTabs()
        reopened.place(changes, in: .side, at: 0)
        reopened.bringForward(changes)
        reopened.markSized(.side)
        reopened.close(changes)
        XCTAssertFalse(reopened.layout.contains(.side))
        XCTAssertEqual(reopened.reopen(preferring: .side), changes)
        XCTAssertEqual(reopened.splitRegions, [.main, .side])
        XCTAssertEqual(reopened.unsized, [.side], "a new leaf, at a guess again")

        // And the way out: a move that takes the last tab takes the leaf.
        moved.move(fileA, to: .main, at: .max)
        XCTAssertEqual(moved.layout, SplitLayout())
    }

    /// A split asked for beside the column is made beside the column, as
    /// beside any leaf.
    func testSplittingBesideTheColumnAndTheStrip() {
        var tabs = column()
        let shell = terminal()
        guard let under = tabs.split(.side, on: .down, placing: shell) else { return XCTFail("nothing was split") }
        XCTAssertEqual(tabs.splitRegions, [.main, .side, under])
        XCTAssertEqual(tabs.side, [changes, history, files], "the column's tabs are as they were")
        XCTAssertEqual(share(of: under.leaf, along: .row, in: tabs), 1.0 / 3, accuracy: 1e-9, "in the column's width")
        XCTAssertEqual(share(of: .side, along: .column, in: tabs), 0.5, accuracy: 1e-9)
        XCTAssertEqual(share(of: .main, along: .row, in: tabs), 2.0 / 3, accuracy: 1e-9, "the main row didn't move")

        // A tab of the column's own, split off beside it.
        guard let left = tabs.split(.side, on: .left, placing: history) else { return XCTFail("nothing was split") }
        XCTAssertEqual(tabs.splitRegions, [.main, left, .side, under])
        XCTAssertEqual(tabs.side, [changes, files])

        // And beside the strip, while it is up.
        var strip = WorkspaceTabs()
        let first = terminal(), second = terminal()
        strip.place(first, in: .bottom, at: 0)
        strip.bringForward(first)
        guard let beside = strip.split(.bottom, on: .right, placing: second) else { return XCTFail("nothing was split") }
        XCTAssertEqual(strip.splitRegions, [.main, .bottom, beside])
        XCTAssertEqual(share(of: .main, along: .row, in: strip), 1, accuracy: 1e-9)

        // Hidden (as a file from an older build can have it until
        // `showHidden`), it takes no room, and the split is the main row's.
        strip.bottomVisible = false
        guard let third = strip.split(.bottom, on: .left, placing: terminal()) else { return XCTFail("nothing was split") }
        XCTAssertEqual(strip.splitRegions, [third, .main, .bottom, beside])
    }

    /// The column's only tab can't be split off the column: that would be
    /// the same leaf in the same place under another name.
    func testTheColumnsOnlyTabIsNotSplitOffTheColumn() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .side, at: 0)
        tabs.bringForward(changes)
        let before = tabs
        XCTAssertNil(tabs.split(.side, on: .down, placing: changes))
        XCTAssertEqual(tabs, before)

        // Off the main row it can be: the column goes, and the pane is there.
        guard let pane = tabs.split(.main, on: .right, placing: changes) else { return XCTFail("nothing was split") }
        XCTAssertEqual(tabs.splitRegions, [.main, pane])
        XCTAssertFalse(tabs.sideVisible)
    }

    /// The column's only tab dropped back where it is: the leaf, and the
    /// share somebody gave it, stay.
    func testReorderingTheColumnsOnlyTabKeepsItsLeaf() {
        var tabs = WorkspaceTabs()
        tabs.place(changes, in: .side, at: 0)
        tabs.bringForward(changes)
        tabs.layout.resize(.side, to: 240, in: area)
        tabs.markSized(.side)
        let before = tabs
        XCTAssertTrue(tabs.move(changes, to: .side, at: 1))
        XCTAssertEqual(tabs, before)
        XCTAssertEqual(share(of: .side, along: .row, in: tabs), 240.0 / 1201, accuracy: 1e-6)
    }

    func testMarkSized() {
        var tabs = column()
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        XCTAssertEqual(tabs.unsized, [.side, .bottom])
        tabs.markSized(.side)
        XCTAssertEqual(tabs.unsized, [.bottom])
        tabs.markSized(.side)
        tabs.markSized(.pane(UUID()))
        XCTAssertEqual(tabs.unsized, [.bottom])
        tabs.close(shell)
        XCTAssertTrue(tabs.unsized.isEmpty, "a leaf that has gone is waiting for nothing")
    }

    /// A file from before the column and the strip were leaves has their
    /// tabs and no place for them in the tree: each is put where it opens.
    func testNormalizedGivesTheColumnAndTheStripTheirLeaves() {
        let id = UUID()
        let shell = terminal()
        var tabs = WorkspaceTabs()
        tabs.side = [changes, history]
        tabs.sideVisible = true
        tabs.bottom = [shell]
        tabs.panes[id] = WorkspaceTabs.PaneTabs(tabs: [fileA], active: fileA)
        tabs.layout.insert(.pane(id), beside: .main, on: .right)

        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.splitRegions, [.main, .bottom, .pane(id), .side])
        XCTAssertEqual(fixed.unsized, [.side, .bottom])
        XCTAssertEqual(fixed.hiddenLeaves, [.bottom])
        XCTAssertEqual(share(of: .side, along: .row, in: fixed), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(share(of: .main, along: .row, in: fixed), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(share(of: .bottom, along: .column, in: fixed), 0.3, accuracy: 1e-9)
        XCTAssertEqual(fixed.normalized(), fixed)

        tabs.sideLeading = true
        XCTAssertEqual(tabs.normalized().splitRegions, [.side, .main, .bottom, .pane(id)])
    }

    /// A leaf for a column or a strip that has no tabs is taken out, and
    /// what was waiting on a leaf that isn't there is forgotten.
    func testNormalizedDropsAColumnOrStripLeafWithNoTabs() {
        var tabs = WorkspaceTabs()
        tabs.layout.insert(.side, atRootEdge: .right, share: 0.3)
        tabs.layout.insert(.bottom, beside: .main, on: .down, share: 0.3)
        tabs.unsized = [.side, .bottom, .pane(UUID())]
        tabs.sideVisible = true
        tabs.zoomed = .side
        let fixed = tabs.normalized()
        XCTAssertEqual(fixed.layout, SplitLayout())
        XCTAssertTrue(fixed.unsized.isEmpty)
        XCTAssertNil(fixed.zoomed)
        XCTAssertFalse(fixed.sideVisible)
    }

    /// A tree that was saved with them in it is left as it was: the shares
    /// in it are somebody's, not a guess.
    func testNormalizedLeavesSavedSharesAlone() {
        var tabs = column()
        tabs.layout = SplitLayout(root: .split(.row, [.init(node: .leaf(.side), weight: 0.25),
                                                      .init(node: .leaf(.main), weight: 0.75)]))
        tabs.unsized = []
        XCTAssertEqual(tabs.normalized(), tabs)
    }
}
