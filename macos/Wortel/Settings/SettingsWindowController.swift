import AppKit
import SwiftUI

/// The Settings window (Wortel ▸ Settings…, ⌘,).
///
/// A standard titled window, not the main window's custom titlebar: it has no
/// row of controls to hold, and looking like the system's is the point. One
/// at a time, made when asked for and let go when closed, so nothing of it
/// exists while it is off screen.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    /// The width of the system's own narrow settings panes.
    private static let width: CGFloat = 460

    init(settings: AppSettings, updater: Updater) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.tabbingMode = .disallowed
        // Where you are, and over a full-screen terminal rather than on the
        // space the app was launched in (as the preview windows are).
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Not state: a relaunch shouldn't reopen it.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        // The form says how tall it is, and the window follows: rows come and
        // go with the build (see `SettingsView`), so no height is right for
        // all of them. A fixed width, or a grouped form has no ideal one.
        let hosting = NSHostingController(
            rootView: SettingsView(settings: settings, updater: updater)
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        // After the first placement, so it comes back where it was left.
        window.setFrameAutosaveName("settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // A field still being edited commits before the window goes.
        window?.makeFirstResponder(nil)
        onClose?()
    }
}
