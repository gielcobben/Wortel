import AppKit
import SwiftUI

/// The Settings window (Wortel ▸ Settings…, ⌘,).
///
/// The Mac's own preferences window: icon tabs in the toolbar, the window
/// named for the tab in front and growing or shrinking to fit it. Built from
/// `NSTabViewController` in its toolbar style, which is what gives the tabs
/// their system look and their keyboard and accessibility behaviour. One at
/// a time, made when asked for and let go when closed, so nothing of it
/// exists while it is off screen.
///
/// Tried on the way here, 2026-11-18: one pane with no toolbar (correct by
/// the book for five rows, and read as a dialog, not as settings), and
/// Wortel's own titlebar and page (the one window on a Mac where settings
/// would not look like settings).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(settings: AppSettings, updater: Updater) {
        let tabs = SettingsTabs(settings: settings, updater: updater)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Centred icons with their names under them: a preferences toolbar.
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        // Where you are, and over a full-screen terminal rather than on the
        // space the app was launched in (as the preview windows are).
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Not state: a relaunch shouldn't reopen it.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        tabs.fitWindow(animated: false)
        window.center()
        // After the first placement, so it comes back where it was left.
        // Only where: its size is the front tab's, set above.
        window.setFrameAutosaveName("settings")
        tabs.fitWindow(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Nothing focused as it opens: AppKit would put the caret in the
        // command field, the one text field here, as if it were asking to be
        // filled in.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        // A field still being edited commits before the window goes.
        window?.makeFirstResponder(nil)
        onClose?()
    }
}

/// The two panes behind the toolbar's tabs.
@MainActor
private final class SettingsTabs: NSTabViewController {
    init(settings: AppSettings, updater: Updater) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // The window's resize is the transition. A crossfade under it showed
        // both panes at once, at two heights.
        transitionOptions = []
        add("General", symbol: "gearshape", GeneralSettingsPane(settings: settings))
        add("Updates", symbol: "arrow.down.circle", UpdatesSettingsPane(updater: updater))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func add<Pane: View>(_ name: String, symbol: String, _ pane: Pane) {
        // The pane says how tall it is at the window's one width: its rows
        // come and go with the build, so no height is right for all of them.
        let hosting = NSHostingController(
            rootView: pane.frame(width: SettingsPane.width).fixedSize(horizontal: false, vertical: true))
        hosting.sizingOptions = [.preferredContentSize]
        // AppKit names the window for the controller in front, and one with
        // no title made it "Untitled" on the first switch of tabs.
        hosting.title = name
        let item = NSTabViewItem(viewController: hosting)
        item.label = name
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: true)
    }

    /// Name the window for the tab in front and make it that tab's height,
    /// keeping its top edge where it is, as a preferences window does.
    func fitWindow(animated: Bool) {
        guard let window = view.window, selectedTabViewItemIndex >= 0 else { return }
        let item = tabViewItems[selectedTabViewItemIndex]
        window.title = item.label
        guard let pane = item.viewController?.view else { return }
        let size = pane.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}
