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
}
