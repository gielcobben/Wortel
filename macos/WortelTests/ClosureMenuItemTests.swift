import AppKit
import XCTest

/// `ClosureMenuItem` has to survive being **copied**, and that requirement is
/// invisible at every call site: nothing in this app ever calls `copy()` on one.
/// AppKit does. `NSToolbarClippedItemsIndicator` copies each item's
/// `menuFormRepresentation` when it builds the toolbar's `»` menu, and
/// `-[NSMenuItem copyWithZone:]` performs that copy by calling the designated
/// initializer on the subclass.
///
/// When the closure was a non-optional stored property, that initializer could
/// not be inherited and Swift emitted a trapping stub in its place — so opening
/// the overflow menu killed the app outright (EXC_BREAKPOINT), with nothing of
/// ours on the stack above AppKit. It stayed latent for as long as no item
/// happened to be clipped, which is exactly the kind of bug that ships.
///
/// These run without a window: an NSMenuItem copy is a value operation.
final class ClosureMenuItemTests: XCTestCase {
    /// The crash itself. Before the fix this line trapped rather than failing.
    func testCopyingDoesNotTrap() {
        let item = ClosureMenuItem(title: "Fetch") {}
        XCTAssertNotNil(item.copy() as? ClosureMenuItem)
    }

    /// A copy that can't run its closure is a dead entry in the `»` menu — the
    /// control is silently lost rather than crashing, which is worse to notice.
    func testCopyStillRunsTheClosure() {
        var fired = 0
        let item = ClosureMenuItem(title: "Push") { fired += 1 }
        guard let duplicate = item.copy() as? ClosureMenuItem,
              let action = duplicate.action else {
            return XCTFail("copy produced no actionable item")
        }
        _ = duplicate.target?.perform(action, with: duplicate)
        XCTAssertEqual(fired, 1)
    }

    /// The copy must own its closure rather than forwarding to the original:
    /// AppKit makes the copy precisely because it intends to outlive the item it
    /// came from, and a target left pointing at a deallocated original is a dead
    /// entry again.
    func testCopyOutlivesTheOriginal() {
        var fired = 0
        var duplicate: ClosureMenuItem?
        autoreleasepool {
            let item = ClosureMenuItem(title: "Fetch") { fired += 1 }
            duplicate = item.copy() as? ClosureMenuItem
        }
        guard let duplicate, let action = duplicate.action else {
            return XCTFail("copy produced no actionable item")
        }
        XCTAssertTrue(duplicate.target === duplicate, "a copy must be its own target")
        _ = duplicate.target?.perform(action, with: duplicate)
        XCTAssertEqual(fired, 1)
    }

    /// AppKit's own copying does the rest of the work; the override must not
    /// have replaced it with a hand-rolled one that drops fields.
    func testCopyKeepsWhatAppKitCopies() {
        let item = ClosureMenuItem(title: "Switch Branch…") {}
        item.state = .on
        item.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        item.submenu = NSMenu(title: "sub")
        let duplicate = item.copy() as? ClosureMenuItem
        XCTAssertEqual(duplicate?.title, "Switch Branch…")
        XCTAssertEqual(duplicate?.state, .on)
        XCTAssertNotNil(duplicate?.image)
        XCTAssertEqual(duplicate?.submenu?.title, "sub")
    }
}
