import AppKit
import SwiftUI

/// The Settings window (Wortel ▸ Settings…, ⌘,), drawn as Wortel's own
/// windows are: the titlebar row on the window's glass, holding the two tabs
/// as the app's tabs are drawn, and the rows on an opaque page under its
/// hairline. The
/// layers are the main window's and the preview window's
/// (`BackdropController`, `ChromePaneController`).
///
/// The system's preferences window (icon tabs, a grouped form) was built and
/// used first, on 2026-11-18, and this one was chosen over it. One at a
/// time, made when asked for and let go when closed, so nothing of it exists
/// while it is off screen.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let state: SettingsTabState
    private var movability: WindowMovability?

    init(settings: AppSettings, updater: Updater) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        // The main window's titlebar (AppDelegate): transparent so the row
        // under it takes the clicks, no title, no separator (the row draws
        // its own hairline), and an empty compact toolbar for the one thing
        // only it does: the row's height, with the traffic lights centred.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "wortel.settings")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // Where you are, and over a full-screen terminal rather than on the
        // space the app was launched in (as the preview windows are).
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Not state: a relaunch shouldn't reopen it.
        window.isRestorable = false
        // Not shown (the row's switch names the tab), but the Window menu,
        // Mission Control and VoiceOver still read it.
        window.title = "Settings"

        state = SettingsTabState(settings: settings)
        // What the rows need, before anything is on screen: the window opens
        // at its size, not at a guess that it then grows out of.
        let rows = NSHostingController(
            rootView: SettingsRows(state: state, settings: settings, updater: updater))
        let height = rows.sizeThatFits(in: NSSize(width: SettingsMetrics.width, height: 10_000)).height
        super.init(window: window)
        window.delegate = self

        let page = NSHostingController(rootView: SettingsPage(
            state: state, settings: settings, updater: updater,
            onHeight: { [weak self] height in self?.fit(rows: height, animated: true) }))
        // The window's size is the window's business (`fit`): left to the
        // hosting controller, a root with no size of its own collapses it.
        page.sizingOptions = []
        page.view.clipsToBounds = true
        let bar = SettingsBar(state: state)
        let pane = ChromePaneController(bar: bar, content: page, bodyColor: Chrome.content)
        window.contentViewController = BackdropController(child: pane)
        movability = WindowMovability(window: window)

        // Once for the window, whichever tab is in front and however often
        // they are switched: this runs the login shell.
        Task { [state] in state.agentsFound = await AgentDiscovery.find() }

        fit(rows: height, animated: false)
        window.center()
        // After the first placement, so it comes back where it was left.
        // Only where: its height is the front tab's.
        window.setFrameAutosaveName("settings")
        fit(rows: height, animated: false)
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
        // A command still being typed is saved before the window goes. Said
        // outright: ending the field's editing does it too, but only if the
        // view gets one more update, and a window on its way out may not.
        state.commitCommand()
        window?.makeFirstResponder(nil)
        // Its event monitor outlives it otherwise, one per window opened.
        movability?.invalidate()
        movability = nil
        onClose?()
    }

    /// Make the window as tall as its rows, keeping its top edge where it
    /// is, as a settings window does when its tab changes. Called with the
    /// rows' own height whenever that changes (`SettingsPage.onHeight`): a
    /// tab switched, or a line under a row wrapping onto a second one.
    private func fit(rows: CGFloat, animated: Bool) {
        guard let window, rows > 0 else { return }
        // The whole window is content here (`fullSizeContentView`): the
        // titlebar row is ours, on top of the page.
        let height = (Chrome.titlebarHeight + rows).rounded(.up)
        guard abs(window.frame.height - height) > 0.5 || window.frame.width != SettingsMetrics.width
        else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: SettingsMetrics.width, height: height)
        if animated, window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                // A pane opening or closing, by the app's own clock.
                context.duration = height > window.frame.height ? Motion.opening : Motion.closing
                context.timingFunction = Motion.curve
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

/// The window's titlebar row: one of the app's rows, holding the two tabs in
/// its middle. Empty space moves the window and double-click zooms it
/// (`ChromeBarView`).
@MainActor
private final class SettingsBar: ChromeBarView {
    init(state: SettingsTabState) {
        super.init()
        let tabs = NSHostingView(rootView: SettingsTabStrip(state: state))
        tabs.sizingOptions = [.intrinsicContentSize]
        tabs.safeAreaRegions = []
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        NSLayoutConstraint.activate([
            // Centred in the row. In a window this narrow the two tabs are
            // the whole row, and started after the traffic lights they left
            // the right half of it empty.
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabs.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Chrome.trafficLightInset),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
