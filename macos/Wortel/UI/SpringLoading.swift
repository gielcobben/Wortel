import AppKit

/// A drag held still over a Wortel window that another is in front of brings
/// it forward, as the Finder does with its windows: so a session, a tab or a
/// file can be taken to a window you can only see a corner of. The Mac's own
/// setting decides whether, and how long the pause is (Accessibility ▸
/// Pointer Control ▸ Spring-loading).
///
/// Every drag that can end in another window reports where the pointer is:
/// a session row (`SidebarOutline`), a tab (`TabDragController`), a file out
/// of a list (`RowClickCatcher`) and a preview window dragged by its row
/// (`PreviewWindowController`). Only main windows come forward, and only
/// while the button is still down: a timer that outlives its drag does
/// nothing.
@MainActor
enum SpringLoading {
    /// Whether a window is one that may come forward: a main window. Set by
    /// AppDelegate.
    static var raisable: (NSWindow) -> Bool = { _ in false }

    private static weak var candidate: NSWindow?
    private static weak var dragged: NSWindow?
    private static var timer: Timer?

    /// The Mac's switch for it, on unless turned off.
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
    }

    /// The Mac's pause before it springs, in seconds; half a second if never set.
    private static var delay: TimeInterval {
        let value = UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        return min(max(value, 0.1), 2)
    }

    /// The pointer is at `screenPoint`, carrying something. `dragged` is a
    /// window that follows the pointer (a preview window, a tab's ghost):
    /// it's under the pointer by definition, so it is looked past, and it
    /// stays in front of the window that comes forward.
    static func hover(at screenPoint: NSPoint, dragging dragged: NSWindow? = nil) {
        guard isEnabled else { return end() }
        self.dragged = dragged
        let under = window(at: screenPoint, excluding: dragged)
        guard let under, raisable(under), !isFrontmost(under) else { return end() }
        guard under !== candidate || timer == nil else { return }
        timer?.invalidate()
        candidate = under
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { spring() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The drag is over, however it ended.
    static func end() {
        timer?.invalidate()
        timer = nil
        candidate = nil
        dragged = nil
    }

    private static func spring() {
        timer = nil
        // Still dragging, and still over it.
        guard NSEvent.pressedMouseButtons & 1 != 0, let candidate,
              window(at: NSEvent.mouseLocation, excluding: dragged) === candidate else { return }
        if let dragged, dragged.isVisible, dragged.level == candidate.level {
            candidate.order(.below, relativeTo: dragged.windowNumber)
        } else {
            candidate.orderFront(nil)
        }
    }

    /// The window a click there would land in, looking past `excluding`;
    /// nil when that isn't ours (another app's, the desktop). Drag images
    /// and a tab's ghost take no clicks, so they are never it.
    private static func window(at point: NSPoint, excluding: NSWindow?) -> NSWindow? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: excluding?.windowNumber ?? 0)
        return NSApp.window(withWindowNumber: number)
    }

    /// In front of every other main window.
    private static func isFrontmost(_ window: NSWindow) -> Bool {
        NSApp.orderedWindows.first { $0.isVisible && !$0.isMiniaturized && raisable($0) } === window
    }
}
