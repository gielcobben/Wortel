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

    /// Files and browsers open in the column until you've moved one.
    func testFilesAndBrowsersStartInTheColumn() {
        let tabs = WorkspaceTabs()
        XCTAssertEqual(tabs.home(for: .file("/tmp/a.md")), .side)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .side)
    }

    /// Moving one to another row is where the next of its kind opens, and
    /// only its kind.
    func testMovingATabMakesItsRowHomeForItsKind() {
        var tabs = WorkspaceTabs()
        let browser = SideTab.browser(UUID())
        tabs.place(browser, in: .side, at: 0)
        tabs.move(browser, to: .main, at: .max)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .main)
        XCTAssertEqual(tabs.home(for: .file("/tmp/a.md")), .side, "files keep their own habit")

        tabs.move(browser, to: .bottom, at: 0)
        XCTAssertEqual(tabs.home(for: .browser(UUID())), .bottom, "the last move wins")
    }

    /// A move asked for once (⌥-click) isn't a habit.
    func testAMoveThatRecordsNoHabitLeavesTheHabitAlone() {
        var tabs = WorkspaceTabs()
        let file = SideTab.file("/tmp/a.md")
        tabs.place(file, in: .side, at: 0)
        tabs.move(file, to: .main, at: .max, recordsHabit: false)
        XCTAssertEqual(tabs.region(of: file), .main)
        XCTAssertEqual(tabs.home(for: .file("/tmp/b.md")), .side)
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
        let file = SideTab.file("/Users/giel/Developer/wortel/README.md")
        XCTAssertEqual(SideTab(rawValue: file.rawValue), file)
        XCTAssertEqual(file.rawValue, "file:/Users/giel/Developer/wortel/README.md")
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
}
