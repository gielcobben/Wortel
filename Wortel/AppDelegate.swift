import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Notification userInfo key carrying the session UUID string, so a tap can
    /// route back to the right session.
    private static let sessionKey = "sessionID"
    private(set) var runtime: GhosttyRuntime!
    private var manager: SessionManager!
    private var window: NSWindow!
    /// The three-pane shell. Held so the toolbar's tracking separators can bind to
    /// its split view, and so ⌘⌥S/⌘⌥G reach the right controller.
    private var splitController: MainSplitViewController!
    /// Drives the trailing source-control panel (hidden by default).
    private let gitPanel = GitPanelModel()
    /// Sparkle auto-updater. Constructed here (rather than lazily) so scheduled
    /// background update checks start at launch; the "Check for Updates…" menu
    /// item drives manual checks through it.
    private let updater = Updater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu must exist before launch so key equivalents resolve immediately.
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else {
            fatalError("failed to initialize libghostty")
        }
        self.runtime = runtime

        let manager = SessionManager(runtime: runtime)
        self.manager = manager

        // AppKit window hosting a SwiftUI NavigationSplitView (the Opslan
        // layout). fullSizeContentView so the sidebar runs to the top; SwiftUI
        // drives the title/toolbar/floating sidebar itself.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .disallowed
        // Drop the hairline the system draws under the titlebar/toolbar so the
        // terminal and sidebar run edge-to-edge with no border bottom.
        window.titlebarSeparatorStyle = .none
        // The unified style is what splits the titlebar into per-pane sections, so
        // the title sits against the sidebar's trailing edge and toolbar items
        // stop at the inspector's leading edge. Set here rather than via
        // .windowToolbarStyle because that modifier is Scene-level and this app is
        // an AppDelegate hosting SwiftUI, not an App struct — no Scene to hang it
        // off. On macOS 26 the items pick up Liquid Glass automatically (it keys
        // off the linked SDK, not the deployment target); on 14 they render as a
        // conventional unified toolbar.
        window.toolbarStyle = .unified
        let split = MainSplitViewController(runtime: runtime, manager: manager, git: gitPanel)
        self.splitController = split
        window.contentViewController = split
        installToolbar(on: window, splitView: split.splitView)
        window.setFrameAutosaveName("main")
        if window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        self.window = window

        manager.onAllClosed = { [weak self] in self?.window?.close() }
        manager.confirmClose = { [weak self] session, completion in
            self?.confirmClose(session, completion: completion)
        }
        manager.onNeedsAttention = { [weak self] session, kind, title, body, alert in
            self?.postAttentionNotification(session, kind: kind, title: title, body: body, alert: alert)
        }
        // A command finished in the selected session → refresh the git panel
        // (it debounces and no-ops while hidden).
        manager.onCommandFinished = { [weak self] session in
            guard let self, session.id == self.manager.selectedID else { return }
            self.gitPanel.refreshCurrent()
        }
        manager.onAttentionCleared = { session in
            // The user answered (or the session closed) — pull the banner out
            // of Notification Center instead of leaving it stale.
            let center = UNUserNotificationCenter.current()
            let id = session.id.uuidString
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
        }

        // Occlusion drives "can the user actually see the window": an active
        // app with a miniaturized or fully covered window should still get
        // attention signals for its selected session.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)

        // Native "a session needs you" notifications. The signal is
        // program-authored (e.g. Claude Code emits OSC 777 on a permission/idle
        // prompt because libghostty sets TERM_PROGRAM=ghostty) — we just relay
        // it. Ask once; if the user declines, the sidebar dot + Dock badge still
        // work.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        manager.restore()
        // Seed the panel with the selected session's cwd so the first toggle
        // resolves the right repo (no git work runs while it's hidden).
        gitPanel.focus(cwd: manager.selected?.cwd)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        observeWindowTitle()
    }

    /// The toolbar is retained here because NSWindow doesn't own its delegate.
    private var toolbarDelegate: MainToolbarDelegate?

    private func installToolbar(on window: NSWindow, splitView: NSSplitView) {
        let delegate = MainToolbarDelegate(splitView: splitView)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "wortel.main")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    /// The window title used to come from SwiftUI's .navigationTitle, which only
    /// exists inside a NavigationSplitView — gone with the AppKit shell, so drive
    /// NSWindow's own title/subtitle instead. Unified toolbar style puts them in
    /// the content section, i.e. starting at the sidebar's trailing edge.
    /// @Observable tracking is one-shot, so the observer re-arms after each change.
    private func observeWindowTitle() {
        withObservationTracking {
            _ = manager.selected?.name
            _ = manager.selected?.abbreviatedPath
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyWindowTitle()
                self.observeWindowTitle()
            }
        }
        applyWindowTitle()
    }

    private func applyWindowTitle() {
        window?.title = manager.selected?.name ?? "Wortel"
        window?.subtitle = manager.selected?.abbreviatedPath ?? ""
    }

    // MARK: - Focus tracking (drives "actively viewing" → no attention shout)

    func applicationDidBecomeActive(_ notification: Notification) {
        manager?.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        manager?.appDidResignActive()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard let window else { return }
        manager?.windowVisibilityChanged(window.occlusionState.contains(.visible))
    }

    // MARK: - Attention notifications

    /// Post (or replace) the "needs you" notification for a session. Uses the
    /// session id as the request identifier so a chatty program updates one
    /// notification instead of stacking many. Informational "finished" pings
    /// arrive silently; blocked prompts and failures make a sound.
    private func postAttentionNotification(_ session: Session, kind: AttentionKind, title: String, body: String, alert: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Sound only on an escalation the manager flagged, so a program that
        // re-fires the same kind updates the banner text without re-dinging.
        content.sound = (alert && kind.playsSound) ? .default : nil
        content.userInfo = [Self.sessionKey: session.id.uuidString]
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Foreground delivery: still show the banner (the user is in another
    /// session, or away from the keyboard) — we only get here when the session
    /// isn't the actively-viewed one.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the notification jumps to that session and brings Wortel front.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let idString = response.notification.request.content.userInfo[Self.sessionKey] as? String,
           let id = UUID(uuidString: idString) {
            manager?.select(id: id)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.saveNow()
    }

    // MARK: - Close confirmation

    /// Sheets a warning when closing a session that still has a running
    /// process. `completion(true)` proceeds with the close. Falls back to
    /// closing immediately if there's no window to sheet onto.
    private func confirmClose(_ session: Session, completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.name)”?"
        alert.informativeText =
            "A process is still running in this session. Closing it will terminate the process."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Menu actions (reached via the responder chain, target nil)

    @objc func newSession(_ sender: Any?) {
        manager.newSession()
    }

    @objc func newSection(_ sender: Any?) {
        if let name = promptFolderName(title: "New Section", confirm: "Create") {
            manager.addFolder(named: name)
        }
    }

    @objc func closeSession(_ sender: Any?) {
        manager.requestCloseSelected()
    }

    @objc func renameSession(_ sender: Any?) {
        manager.beginRenameSelected()
    }

    @objc func selectNextSession(_ sender: Any?) {
        manager.selectNext()
    }

    @objc func selectPreviousSession(_ sender: Any?) {
        manager.selectPrevious()
    }

    @objc func selectNextAttentionSession(_ sender: Any?) {
        manager.selectNextAttention()
    }

    @objc func selectSessionAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        manager.select(index: item.tag)
    }

    @objc func toggleSourceControl(_ sender: Any?) {
        gitPanel.toggle()
    }

    @objc func focusSourceControlList(_ sender: Any?) {
        gitPanel.requestListFocus()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// Grey out "Check for Updates…" while a check is already in flight (Sparkle
    /// drops `canCheckForUpdates` to false for the duration).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updater.canCheckForUpdates
        }
        if menuItem.action == #selector(toggleSourceControl(_:)) {
            menuItem.title = gitPanel.isVisible ? "Hide Source Control" : "Show Source Control"
            return true
        }
        // Only offer "Next Waiting Session" when something is actually waiting.
        if menuItem.action == #selector(selectNextAttentionSession(_:)) {
            return manager?.hasAttention ?? false
        }
        return true
    }
}
