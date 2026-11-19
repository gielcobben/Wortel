import AppKit
import XCTest

/// The main window's `isMovable`, which decides whether a press on a titlebar
/// tab drags the tab or the whole window. Both ways it went wrong were silent:
/// tabs still drew, still selected, and the window moved instead. These pin
/// the rule down: off unless the pointer is outside the window, a menu is
/// open or fn-⌃ is held, and off from the start.
@MainActor
final class WindowMovabilityTests: XCTestCase {
    private var window: NSWindow!
    private var movability: WindowMovability!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            // Far off screen, so the pointer is certainly not over it: the case
            // that left the window movable from launch on.
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.isMovable = true
            self.window = window
            movability = WindowMovability(window: window)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            movability.invalidate()
            window.close()
            window = nil
            movability = nil
        }
        super.tearDown()
    }

    private func crossing(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    /// Crossings go the way the tracking area sends them, by Objective-C
    /// selector. Calling the Swift methods passed while the selectors they
    /// were exported under were `mouseEnteredWith:` and `mouseExitedWith:`,
    /// and every real crossing raised "unrecognized selector".
    private func pointerExits() {
        movability.perform(#selector(NSResponder.mouseExited(with:)), with: crossing(.mouseExited))
    }

    private func pointerEnters() {
        movability.perform(#selector(NSResponder.mouseEntered(with:)), with: crossing(.mouseEntered))
    }

    /// Worked out from where the pointer was, this read "outside" before the
    /// window had its saved frame, and a tab grabbed in it moved the window
    /// until the pointer happened to leave and come back.
    func testStartsNotMovableWhereverThePointerIs() {
        XCTAssertFalse(window.isMovable)
    }

    func testMovableOnlyWhileThePointerIsOutsideTheWindow() {
        pointerExits()
        XCTAssertTrue(window.isMovable, "the menu bar and the Dock are outside: tiling from there works")
        pointerEnters()
        XCTAssertFalse(window.isMovable, "back inside, a press on a tab must drag the tab")
    }

    func testMovableWhileAMenuIsOpen() {
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertTrue(window.isMovable, "the Window menu greys out Fill and Center otherwise")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(window.isMovable)
    }

    func testMovableWhileFnControlIsHeld() {
        movability.modifiersChanged([.function, .control])
        XCTAssertTrue(window.isMovable, "fn-⌃F and the rest of the tiling shortcuts")
        movability.modifiersChanged([.function, .control, .shift])
        XCTAssertTrue(window.isMovable, "fn-⌃⇧ arrows")
        movability.modifiersChanged([])
        XCTAssertFalse(window.isMovable)
    }

    /// ⌃ and ⌘ are down half the time in a terminal. A tab grabbed with ⌘
    /// still held from ⌘T, or ⌃-clicked for its menu, must still be the tab.
    func testOtherModifiersLeaveItOff() {
        for flags: NSEvent.ModifierFlags in [.control, .command, .option, .function, .shift, .capsLock,
                                             [.command, .control], [.option, .command]] {
            movability.modifiersChanged(flags)
            XCTAssertFalse(window.isMovable, "\(flags) held")
        }
    }

    func testOneMenuClosingLeavesItOnWhileAnotherIsOpen() {
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertTrue(window.isMovable)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(window.isMovable)
    }

    /// A menu tracks its own events, so keys let go while it's up are never
    /// seen as they go; closing it reads them again.
    func testClosingAMenuReadsTheKeysAgain() {
        movability.modifiersChanged([.function, .control])
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(window.isMovable, "nothing is held now")
    }

    /// Each reason holds on its own: the pointer coming back in while a menu
    /// is still open doesn't turn it off under the menu.
    func testReasonsAreIndependent() {
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        pointerExits()
        pointerEnters()
        XCTAssertTrue(window.isMovable)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(window.isMovable)
    }
}
