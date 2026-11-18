import AppKit
import SwiftUI

/// The Settings window (Wortel ▸ Settings…, ⌘,), drawn as Wortel's own
/// windows are: the titlebar row on the window's glass, with the two tabs as
/// the row's switch, and the rows on an opaque page under its hairline. The
/// layers are the main window's and the preview window's
/// (`BackdropController`, `ChromePaneController`).
///
/// An experiment (2026-11-18) beside the system's preferences window, which
/// is the commit before this one. One at a time, made when asked for and let
/// go when closed, so nothing of it exists while it is off screen.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let state = SettingsTabState()
    private let page: NSHostingController<SettingsPage>
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

        page = NSHostingController(rootView: SettingsPage(state: state, settings: settings, updater: updater))
        // The window's size is the window's business (`fit`): left to the
        // hosting controller, a root of flexible frames collapses it.
        page.sizingOptions = []
        super.init(window: window)
        window.delegate = self

        let bar = SettingsBar(state: state) { [weak self] in self?.fit(animated: true) }
        let pane = ChromePaneController(bar: bar, content: page, bodyColor: Chrome.content)
        window.contentViewController = BackdropController(child: pane)
        movability = WindowMovability(window: window)

        fit(animated: false)
        window.center()
        // After the first placement, so it comes back where it was left.
        // Only where: its height is the front tab's.
        window.setFrameAutosaveName("settings")
        fit(animated: false)
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

    /// Make the window the height of the tab in front, keeping its top edge
    /// where it is, as a settings window does when its tab changes.
    private func fit(animated: Bool) {
        guard let window else { return }
        // Offered no height at all, the page answers with what its rows
        // need. Offered plenty, it takes all of it (it fills the window so
        // the rows stay at the top while the window's height moves), and the
        // window came out ten thousand points tall.
        let rows = page.sizeThatFits(in: NSSize(width: SettingsMetrics.width, height: 0)).height
        guard rows > 0 else { return }
        // The whole window is content here (`fullSizeContentView`): the
        // titlebar row is ours, on top of the page.
        let height = Chrome.titlebarHeight + rows
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

/// The window's titlebar row: one of the app's rows, holding the switch
/// between the two tabs, centred. Empty space moves the window and
/// double-click zooms it (`ChromeBarView`).
@MainActor
private final class SettingsBar: ChromeBarView {
    init(state: SettingsTabState, onChange: @escaping () -> Void) {
        super.init()
        let tabs = NSHostingView(rootView: SettingsTabSwitch(state: state, onChange: onChange))
        tabs.sizingOptions = [.intrinsicContentSize]
        tabs.safeAreaRegions = []
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// General · Updates, as the preview window's row has Diff · Source ·
/// Rendered: the app's own switch, not the system's tabs.
private struct SettingsTabSwitch: View {
    @Bindable var state: SettingsTabState
    let onChange: () -> Void

    var body: some View {
        PillSwitch(items: SettingsTab.allCases, title: \.rawValue, selection: $state.tab)
            // A turn later, once the page has the new tab's rows to measure.
            .onChange(of: state.tab) { DispatchQueue.main.async { onChange() } }
    }
}
