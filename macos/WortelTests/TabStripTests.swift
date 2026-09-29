import AppKit
import XCTest

/// The tab rows sit in a transparent titlebar, and that is where AppKit does
/// the most on your behalf: it insets scroll views under the titlebar, it moves
/// the window from presses on anything that isn't a control, it puts its own
/// effect views over content. Every one of those broke the rows at least once
/// without anything failing, the tabs still drew and simply stopped taking
/// clicks. So these build a window configured exactly like Wortel's and check
/// the row still does its job in it.
@MainActor
final class TabStripTests: XCTestCase {
    private var window: NSWindow!
    private var strip: SideTabStrip!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = NSToolbar(identifier: "wortel.tests")
            window.toolbarStyle = .unifiedCompact
            window.isMovable = false
            let root = NSView(frame: window.contentView!.bounds)
            window.contentView = root
            // Where the column's row sits: the top 40pt, under the titlebar, and
            // clear of the traffic lights (the row is never under them: when it's
            // leftmost it's inset past them).
            let strip = SideTabStrip(frame: NSRect(x: 300, y: root.bounds.height - 40, width: 500, height: 40))
            strip.trailingAccessory = HoverFillButton.glyph("plus", "New Tab")
            root.addSubview(strip)
            self.window = window
            self.strip = strip
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            window.close()
            window = nil
            strip = nil
        }
        super.tearDown()
    }

    @discardableResult
    private func show(_ count: Int, active: Int = 0) -> [SideTab] {
        show(titles: (0..<count).map { "Terminal \($0)" }, active: active)
    }

    @discardableResult
    private func show(titles: [String], active: Int = 0) -> [SideTab] {
        let tabs = titles.map { _ in SideTab.terminal(UUID()) }
        let items = zip(tabs, titles).map {
            SideTabStrip.Item(tab: $0.0, title: $0.1, symbol: "apple.terminal")
        }
        strip.update(items: items, active: tabs[active])
        strip.needsLayout = true
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        return tabs
    }

    /// The row's tabs, in order, as laid out in the scrolling content.
    private var tabViews: [NSView] {
        (strip.scroll.documentView?.subviews ?? []).sorted { $0.frame.minX < $1.frame.minX }
    }

    private func hit(_ point: NSPoint, in view: NSView) -> NSView? {
        window.contentView?.superview?.hitTest(view.convert(point, to: nil))
    }

    // MARK: - Clicks

    /// The regression this file exists for: a scroll view in a transparent
    /// titlebar insets itself by the titlebar's height and puts an effect view
    /// over its content, and every click on a tab went to that instead.
    func testEveryTabTakesItsOwnClickUnderATransparentTitlebar() {
        show(3)
        XCTAssertEqual(strip.scroll.contentInsets.top, 0, "never inset under the titlebar")
        for tab in tabViews {
            let centre = NSPoint(x: tab.bounds.midX, y: tab.bounds.midY)
            let target = hit(centre, in: tab)
            XCTAssertTrue(target === tab, "a click on a tab lands on the tab, not \(String(describing: target))")
        }
    }

    func testTheFrontTabsCloseButtonTakesItsClick() {
        show(3, active: 0)
        let front = try! XCTUnwrap(tabViews.first)
        // The close button is the last 20pt of the tab, 4pt in from its end.
        let point = NSPoint(x: front.bounds.maxX - 14, y: front.bounds.midY)
        let target = hit(point, in: front)
        XCTAssertTrue(target is NSButton, "the × takes the click, not \(String(describing: target))")
        XCTAssertTrue(target?.isDescendant(of: front) == true)
    }

    // MARK: - Scrolling

    func testTheRowNeverScrollsVertically() {
        show(12)
        let clip = strip.scroll.contentView
        XCTAssertEqual(strip.scroll.documentView?.frame.height, clip.bounds.height,
                       "nothing to scroll up or down to")
        strip.scroll.scrollWheel(with: wheel(dx: 0, dy: -40))
        XCTAssertEqual(clip.bounds.origin.y, 0, "a vertical wheel never moves the row vertically")
        XCTAssertGreaterThan(clip.bounds.origin.x, 0, "it scrolls the row sideways instead")
    }

    func testARowThatFitsDoesntScroll() {
        show(2)
        strip.scroll.scrollWheel(with: wheel(dx: 0, dy: -40))
        XCTAssertEqual(strip.scroll.contentView.bounds.origin, .zero)
    }

    /// Too many tabs: each stays readable, the row scrolls, and "+" stays in
    /// view just past the visible end.
    func testAnOverflowingRowKeepsTabsReadableAndPlusInView() {
        show(titles: (0..<12).map { "A long running terminal \($0)" })
        for tab in tabViews {
            XCTAssertGreaterThanOrEqual(tab.frame.width, SideTabStrip.minTabWidth)
        }
        let visible = strip.scroll.frame.width
        XCTAssertGreaterThan(strip.scroll.documentView?.frame.width ?? 0, visible)
        let plus = try! XCTUnwrap(strip.trailingAccessory)
        XCTAssertLessThanOrEqual(plus.frame.maxX, strip.bounds.width, "+ is on screen")
        XCTAssertGreaterThanOrEqual(plus.frame.minX, visible, "+ is past the visible tabs")
    }

    /// Short titles aren't padded to the minimum: Changes, History and Files
    /// fit side by side in a row too narrow for three minimum-width tabs.
    func testShortTitlesKeepTheirOwnWidth() {
        strip.frame.size.width = 380
        show(titles: ["Changes", "History", "Files"])
        XCTAssertEqual(strip.scroll.documentView?.frame.width ?? 0, strip.scroll.frame.width,
                       accuracy: 0.5, "all three fit, nothing to scroll")
        XCTAssertLessThan(tabViews.last?.frame.width ?? .infinity, SideTabStrip.minTabWidth)
    }

    /// Short of room, a long title gives way down to the minimum while a short
    /// one keeps its whole title.
    func testLongTitlesGiveWayBeforeShortOnes() {
        strip.frame.size.width = 360
        show(titles: ["Files", "npm run dev in the web folder of this repo"])
        let squeezed = (short: tabViews[0].frame.width, long: tabViews[1].frame.width)
        XCTAssertGreaterThanOrEqual(squeezed.long, SideTabStrip.minTabWidth)
        XCTAssertLessThan(squeezed.long, SideTabStrip.maxTabWidth, "it gave way")
        strip.frame.size.width = 900
        strip.needsLayout = true
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabViews[0].frame.width, squeezed.short, "Files didn't shrink")
        XCTAssertEqual(tabViews[1].frame.width, SideTabStrip.maxTabWidth, "with room, it's back")
    }

    /// The tab in front is scrolled into view when it's past the edge.
    func testTheTabInFrontIsScrolledIntoView() {
        show(12, active: 11)
        let last = try! XCTUnwrap(tabViews.last)
        let visible = strip.scroll.contentView.bounds
        XCTAssertLessThanOrEqual(last.frame.maxX, visible.maxX + 0.5)
    }

    // MARK: - Drops

    func testDropIndicesRunFromTheStartToTheEnd() {
        show(3)
        let tabs = tabViews
        let first = tabs[0].convert(NSPoint(x: 2, y: 0), to: nil).x
        let last = tabs[2].convert(NSPoint(x: tabs[2].bounds.maxX - 2, y: 0), to: nil).x
        XCTAssertEqual(strip.insertion(atWindowX: first).index, 0)
        XCTAssertEqual(strip.insertion(atWindowX: last).index, 3)
        let second = tabs[1].convert(NSPoint(x: 2, y: 0), to: nil).x
        XCTAssertEqual(strip.insertion(atWindowX: second).index, 1)
    }

    // MARK: - Helpers

    private func wheel(dx: Int32, dy: Int32) -> NSEvent {
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0)!
        return NSEvent(cgEvent: cgEvent)!
    }
}
