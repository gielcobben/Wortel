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

    /// A file dropped into a row from a list is a choice of where files go.
    func testDroppingAFileFromAListMakesItsRowHome() {
        var tabs = WorkspaceTabs()
        tabs.placeDropped(.file("/tmp/a.md"), in: .side, at: 0)
        XCTAssertEqual(tabs.region(of: .file("/tmp/a.md")), .side)
        XCTAssertEqual(tabs.home(for: .file("/tmp/b.md")), .side)
        XCTAssertEqual(tabs.elsewhere(for: .file("/tmp/b.md")), .main)
    }

    /// Moving one to another row is where the next of its kind opens, and
    /// only its kind.
    func testMovingATabMakesItsRowHomeForItsKind() {
        var tabs = WorkspaceTabs()
        let browser = SideTab.browser(UUID())
        tabs.place(browser, in: .side, at: 0)
        tabs.move(browser, to: .main, at: .max)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .main)
        XCTAssertEqual(tabs.home(for: .file("/tmp/a.md")), .main, "files keep their own habit")

        tabs.move(browser, to: .bottom, at: 0)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .bottom, "the last move wins")
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

    /// Which regions are parts of the main area's tree.
    func testRegionsAndLeaves() {
        let id = UUID()
        XCTAssertEqual(TabRegion.main.leaf, .main)
        XCTAssertEqual(TabRegion.pane(id).leaf, .pane(id))
        XCTAssertNil(TabRegion.side.leaf)
        XCTAssertNil(TabRegion.bottom.leaf)
        XCTAssertEqual(TabRegion(.main), .main)
        XCTAssertEqual(TabRegion(.pane(id)), .pane(id))
        XCTAssertTrue(TabRegion.main.isSplitLeaf)
        XCTAssertTrue(TabRegion.pane(id).isSplitLeaf)
        XCTAssertFalse(TabRegion.side.isSplitLeaf)
        XCTAssertFalse(TabRegion.bottom.isSplitLeaf)
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
        XCTAssertEqual(tabs.layout.leaves, [.main, .pane(id)])
        XCTAssertEqual(tabs.region(of: shell), pane)
        XCTAssertEqual(tabs.tabs(in: pane), [shell])
        XCTAssertEqual(tabs.front(of: pane), shell)
        XCTAssertTrue(tabs.isShowing(pane))
        XCTAssertEqual(tabs.splitRegions, [.main, pane])
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
        XCTAssertEqual(tabs.splitRegions, [.main, pane, under])
        XCTAssertEqual(tabs.layout.root, .split(.row, [
            .init(node: .leaf(.main), weight: 0.5),
            .init(node: .split(.column, [.init(node: .leaf(pane.leaf!), weight: 0.5),
                                         .init(node: .leaf(under.leaf!), weight: 0.5)]), weight: 0.5),
        ]))
    }

    /// The column and the strip aren't parts of the main area, and a pane
    /// that has gone isn't either: asked about one, the main row is split.
    func testSplittingWhatIsNotALeafSplitsTheMainRow() {
        for region in [TabRegion.side, .bottom, .pane(UUID())] {
            var tabs = column()
            let shell = terminal()
            guard let pane = tabs.split(region, on: .left, placing: shell) else {
                XCTFail("\(region): nothing was split")
                continue
            }
            XCTAssertEqual(tabs.splitRegions, [pane, .main], "\(region)")
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
        XCTAssertEqual(tabs.splitRegions.count, 3)

        guard let third = tabs.split(second, on: .right, placing: changes) else {
            return XCTFail("nothing was split")
        }
        XCTAssertFalse(tabs.exists(first), "its last tab left, so it went")
        XCTAssertFalse(tabs.layout.contains(first.leaf!))
        XCTAssertEqual(tabs.splitRegions, [.main, second, third])
        XCTAssertEqual(tabs.tabs(in: third), [changes])

        // And when the pane asked about is the one that goes, beside the
        // main row: there is nothing else for it to be beside.
        var other = column()
        let pane = splitOff(changes, from: &other)
        guard let moved = other.split(.pane(UUID()), on: .right, placing: changes) else {
            return XCTFail("nothing was split")
        }
        XCTAssertFalse(other.exists(pane))
        XCTAssertEqual(other.splitRegions, [.main, moved])
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
        XCTAssertTrue(tabs.layout.contains(made.leaf!))
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

    /// A file or a browser split off by a drag makes the pane where its kind
    /// opens; a command (`recordsHabit: false`) doesn't.
    func testSplittingByADragTeachesWhereItsKindGoes() {
        var tabs = column()
        let pane = tabs.split(.main, on: .right, placing: fileA)!
        XCTAssertEqual(tabs.habits[.file], pane)
        XCTAssertEqual(tabs.home(for: fileB), pane)

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
        XCTAssertEqual(tabs.layout, SplitLayout(), "its room went back to the main row")
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
            .init(node: .leaf(first.leaf!), weight: 0.25),
            .init(node: .leaf(second.leaf!), weight: 0.25),
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

        // And a zoom on the main row ends when the main row is all there is.
        var alone = column()
        splitOff(changes, from: &alone)
        alone.toggleZoom(.main)
        alone.close(changes)
        XCTAssertNil(alone.zoomed)
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
        XCTAssertFalse(tabs.layout.isSplit)
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
        XCTAssertEqual(tabs.splitRegions, [.main, second])
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

    func testMovingIntoAPaneTeachesWhereItsKindGoes() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: .main, at: .max)
        tabs.move(fileA, to: pane, at: .max)
        XCTAssertEqual(tabs.home(for: fileB), pane)
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

    /// Only a leaf of the tree, and only while there is more than one.
    func testOnlyALeafOfASplitAreaZooms() {
        var unsplit = column()
        unsplit.toggleZoom(.main)
        XCTAssertNil(unsplit.zoomed, "nothing to zoom out of")

        var tabs = column()
        splitOff(changes, from: &tabs)
        for region in [TabRegion.side, .bottom, .pane(UUID())] {
            tabs.toggleZoom(region)
            XCTAssertNil(tabs.zoomed, "\(region)")
        }
    }

    /// The column and the strip are beside the main area: a zoom doesn't
    /// hide them, and they show as they always do.
    func testZoomLeavesTheColumnAndTheStripAlone() {
        var tabs = column()
        let pane = splitOff(terminal(), from: &tabs)
        tabs.place(terminal(), in: .bottom, at: 0)
        tabs.toggleZoom(pane)
        XCTAssertTrue(tabs.isShowing(.side))
        XCTAssertFalse(tabs.isShowing(.bottom), "the strip is down until a tab comes forward in it")
        tabs.bringForward(tabs.bottom[0])
        XCTAssertTrue(tabs.isShowing(.bottom))
        tabs.sideVisible = false
        XCTAssertFalse(tabs.isShowing(.side))
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

    /// In the zoomed leaf itself, in the column or in the strip, it stays.
    func testBringingForwardElsewhereKeepsTheZoom() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        tabs.place(fileA, in: pane, at: .max)
        let shell = terminal()
        tabs.place(shell, in: .bottom, at: 0)
        tabs.toggleZoom(pane)

        tabs.bringForward(fileA)
        XCTAssertEqual(tabs.zoomed, pane, "a tab of the zoomed pane")
        tabs.bringForward(history)
        XCTAssertEqual(tabs.zoomed, pane, "the column is beside it")
        tabs.bringForward(shell)
        XCTAssertEqual(tabs.zoomed, pane, "and so is the strip")
        tabs.bringForward(opened: files)
        XCTAssertEqual(tabs.zoomed, pane)
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

    func testEqualizeEvensTheLayout() {
        var tabs = WorkspaceTabs()
        let first = tabs.split(.main, on: .right, placing: terminal())!
        let second = tabs.split(first, on: .right, placing: terminal())!
        XCTAssertTrue(tabs.layout.isEqualized, "three splits among equals are thirds")
        tabs.layout = SplitLayout(root: .split(.row, [
            .init(node: .leaf(.main), weight: 0.5),
            .init(node: .leaf(first.leaf!), weight: 0.25),
            .init(node: .leaf(second.leaf!), weight: 0.25),
        ]))
        XCTAssertFalse(tabs.layout.isEqualized)
        let leaves = tabs.layout.leaves
        tabs.equalize()
        XCTAssertTrue(tabs.layout.isEqualized)
        XCTAssertEqual(tabs.layout.leaves, leaves)
    }

    // MARK: Where things open

    /// A habit for a pane that has gone is no habit: the kind's own start.
    func testAHabitForAPaneThatHasGoneFallsBack() {
        var tabs = column()
        let pane = tabs.split(.main, on: .right, placing: fileA)!
        let browser = SideTab.browser(UUID())
        tabs.placeDropped(browser, in: pane, at: .max)
        XCTAssertEqual(tabs.home(for: fileB), pane)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), pane)

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
        XCTAssertEqual(tabs.elsewhere(for: fileB), .main, "it would open in the pane")
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
        XCTAssertFalse(tabs.layout.isSplit)
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
        XCTAssertFalse(tabs.layout.isSplit, "reopening a tab doesn't remake its pane")
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

    /// With files at home in a pane, the preview opens there, and the next
    /// file takes its place in that pane's row.
    func testThePreviewSwapsInPlaceInAPane() {
        var tabs = column()
        let pane = splitOff(a, from: &tabs)
        let id = pane.paneID!
        tabs.place(terminal(), in: pane, at: .max)
        XCTAssertEqual(tabs.peekRegion(for: b, avoiding: .side), pane, "where files go")

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
        tabs.habits[.file] = pane
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: pane), .main, "not over the list")
        XCTAssertEqual(tabs.peekRegion(for: a, avoiding: .side), pane)
        // The preview tab's own row, wherever it is.
        tabs.habits[.file] = nil
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
        XCTAssertEqual(tabs.splitRegions, [leftPane, .main, rightPane])
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
        XCTAssertEqual(tabs.splitRegions, [.main])
        XCTAssertTrue(tabs.panes.isEmpty)
        XCTAssertFalse(tabs.layout.isSplit)
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

    /// A zoom on something that isn't a leaf of a split area is no zoom.
    func testAZoomIsOnALeafThatIsThere() {
        var tabs = column()
        let pane = splitOff(changes, from: &tabs)
        for zoomed in [TabRegion.side, .bottom, .pane(UUID())] {
            tabs.zoomed = zoomed
            XCTAssertNil(tabs.normalized().zoomed, "\(zoomed)")
        }
        tabs.zoomed = pane
        XCTAssertEqual(tabs.normalized().zoomed, pane)
        tabs.zoomed = .main
        XCTAssertEqual(tabs.normalized().zoomed, .main)

        var unsplit = column()
        unsplit.zoomed = .main
        XCTAssertNil(unsplit.normalized().zoomed, "there is nothing to zoom out of")
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
}
