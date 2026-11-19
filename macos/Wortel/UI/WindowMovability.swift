import AppKit

/// Whether the window server may move the main window from a press in its
/// titlebar: only at the moments something else needs it to.
///
/// While `isMovable` is on, the window server moves the window from any press
/// in its transparent titlebar, tabs included, whatever view is under it
/// (e83bbd6). So the titlebar rows move the window themselves from their empty
/// space (`performDrag`, ChromeBarView) and `isMovable` is off. Off for good,
/// though, it also tells AppKit the window can't be moved, which greys out Fill,
/// Center, Move & Resize and their fn-⌃ shortcuts (83f29e0).
///
/// It used to be off only while the pointer was over the titlebar band, turned
/// off by the band's `mouseEntered`. That depended on the event arriving, and
/// arriving before the press: the window server reads `isMovable` at the press,
/// not when the app gets round to it. Grabbing a tab just opened from the Files
/// pane often carried the window instead, and a second try worked. Two ways it
/// loses, neither caught in the act: just after a file opens the main thread is
/// busy (about 350ms of work, `sample` on a test copy, 2026-11-16), and the
/// rows rebuilt their tracking areas with `.assumeInside` as the layout
/// settled, which sends no `mouseEntered` for a pointer already inside.
///
/// So now it's off unless one of these holds, and each one reaches the app
/// before whatever needs the window movable does:
/// - fn and ⌃ are both held: every tiling shortcut the system gives the Window
///   menu is fn-⌃ something, and the modifiers' own event arrives before the
///   key. Not any modifier: ⌃ and ⌘ are down half the time in a terminal, and
///   a tab grabbed with ⌘ still held from ⌘T would have taken the window. A
///   tiling shortcut someone rebound to other keys works from the menu bar.
/// - a menu is open: the Window menu's items are checked as it opens;
/// - the pointer is outside the window: the menu bar, the Dock.
/// Where the pointer is inside the window plays no part. Window managers that
/// move windows through Accessibility don't care either way (checked: a
/// non-movable window still takes a position set through AX).
///
/// What's left: *turning it off* still waits for an event. Pointer straight
/// from the menu bar onto a tab, or fn-⌃ let go and a tab grabbed, while the
/// main thread is busy, can still move the window. Both are far rarer than the
/// pane below, which is now safe whatever the main thread is doing.
///
/// The pointer starts as inside, the safe side. Worked out from the window's
/// frame instead, it ran before the window had its saved frame: the pointer
/// read as outside, nothing said otherwise until it left the window, and the
/// window was movable the whole time (seen in a diagnostics log, 2026-11-16).
/// `WindowMovabilityTests` pins all of this down.
@MainActor
final class WindowMovability: NSObject {
    private weak var window: NSWindow?
    private var pointerOutside = false
    /// A count, not a flag: menus are watched app-wide, and one closing
    /// mustn't turn this off under another still open.
    private var menusOpen = 0
    private var tilingKeysHeld = false
    private var monitor: Any?
    private var tracking: NSTrackingArea?

    static let tilingKeys: NSEvent.ModifierFlags = [.function, .control]

    init(window: NSWindow) {
        self.window = window
        super.init()
        // `.assumeInside`: a pointer that is outside after all says so at its
        // first move, as `mouseExited`.
        let tracking = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self)
        window.contentView?.addTrackingArea(tracking)
        self.tracking = tracking
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
            return event
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(resyncModifiers),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resyncModifiers),
                           name: NSApplication.didResignActiveNotification, object: nil)
        apply()
    }

    /// Stops watching. The app's lives as long as its window; the tests make
    /// one per test, and a tracking area doesn't retain its owner.
    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tracking { window?.contentView?.removeTrackingArea(tracking) }
        tracking = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func apply() {
        let movable = pointerOutside || menusOpen > 0 || tilingKeysHeld
        if window?.isMovable != movable { window?.isMovable = movable }
    }

    /// Internal for the tests, which can't hold a key down.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        tilingKeysHeld = flags.isSuperset(of: Self.tilingKeys)
        apply()
    }

    // The tracking area's owner is sent `mouseEntered:` and `mouseExited:`.
    // Spelled out, because this is an NSObject, not an NSResponder: a plain
    // `@objc func mouseExited(with:)` is exported as `mouseExitedWith:`, so
    // every exit raised "unrecognized selector". AppKit swallowed that in the
    // event loop, but under ⌘O's open panel `runModal` caught it and showed
    // "The open file operation failed to connect to the open and save panel
    // service" (2026-11-18). And the pointer-outside rule never once fired.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { pointerOutside = false; apply() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { pointerOutside = true; apply() }
    @objc private func menuBegan(_ note: Notification) { menusOpen += 1; apply() }

    /// Keys let go while a menu was up never reached the monitor (a menu
    /// tracks its own events), so they're read again here.
    @objc private func menuEnded(_ note: Notification) {
        menusOpen = max(0, menusOpen - 1)
        resyncModifiers()
    }

    /// The monitor only hears the app's own events while it's in front: keys
    /// still down as ⌘-Tab leaves would otherwise read as held until the next
    /// change here.
    @objc private func resyncModifiers() {
        modifiersChanged(NSApp.isActive ? NSEvent.modifierFlags : [])
    }
}
