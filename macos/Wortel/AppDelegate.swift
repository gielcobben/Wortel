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
    /// Drives the trailing source-control panel. Whether it's up follows the
    /// selected session (see GitPanelModel); new sessions start hidden.
    private let gitPanel = GitPanelModel()
    /// Drives the Markdown preview that shares the trailing column — opened by
    /// clicking a `.md` path in the terminal.
    private let markdownPreview = MarkdownPreviewModel()
    /// Drives the Files pane — the third view of the same column. Reads the repo
    /// the git panel has already resolved, so it costs no extra git work.
    private lazy var fileTree = FileTreeModel(git: gitPanel)
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
        let split = MainSplitViewController(
            runtime: runtime, manager: manager, git: gitPanel,
            markdown: markdownPreview, files: fileTree)
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
        // A markdown path was clicked in the terminal → open it in the trailing
        // preview (which shares the column with the git panel).
        manager.onOpenMarkdown = { [weak self] url in
            self?.markdownPreview.open(url)
        }
        // Opening a .md from the file tree goes to the same preview, so a file
        // reached either way lands in one place.
        fileTree.onPreviewMarkdown = { [weak self] url in
            self?.markdownPreview.open(url)
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
        // The grant is remembered because the turn-end chime is played by us,
        // not by Notification Center (see playTurnDoneChime): someone who
        // declined notifications should not be chimed at anyway.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { Self.notificationsAuthorized = granted }
        }

        // Panel visibility and the chosen pane are session state, so a toggle has
        // to reach sessions.json.
        gitPanel.onStateChanged = { [weak manager] in manager?.sessionStateChanged() }

        manager.restore()
        // Point the panel at the restored selection: it's what raises the panel
        // if that session had it up, and it seeds the cwd so the first toggle
        // resolves the right repo (no git work runs while it's hidden).
        gitPanel.focus(session: manager.selected)
        fileTree.focus(session: manager.selected)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        observeWindowTitle()
        observePreviewSession()
    }

    /// The toolbar is retained here because NSWindow doesn't own its delegate.
    private var toolbarDelegate: MainToolbarDelegate?

    private func installToolbar(on window: NSWindow, splitView: NSSplitView) {
        let delegate = MainToolbarDelegate(splitView: splitView, git: gitPanel, markdown: markdownPreview)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "wortel.main")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // The delegate inserts and removes the branch item as the panel opens and
        // closes, so it needs the toolbar it's the delegate of.
        delegate.toolbar = toolbar
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

    /// The markdown preview is app-wide and shares the per-session inspector
    /// column, so it must not outlive the session it was opened from — close it
    /// whenever the selection changes, or it would cover the newly-selected
    /// session's git panel with an unrelated file. @Observable tracking is
    /// one-shot, so the observer re-arms after each change.
    private func observePreviewSession() {
        withObservationTracking {
            _ = manager.selectedID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.markdownPreview.close()
                self.observePreviewSession()
            }
        }
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
        //
        // Only the standard alert goes through UNNotificationSound: on macOS
        // that API reliably plays exactly one sound, `.default`. Naming a system
        // sound is not a documented path and reportedly just plays nothing —
        // and a chime that is silently silent is worse than no chime, since it
        // looks shipped. So the quieter turn-end tier is played directly
        // through NSSound, which does read /System/Library/Sounds.
        // Trade-off: an NSSound isn't routed by Notification Center, so it is
        // heard even when a Focus would have suppressed the banner.
        content.sound = (alert && kind.chime == .alert) ? .default : nil
        if alert, kind.chime == .soft { Self.playTurnDoneChime() }
        content.userInfo = [Self.sessionKey: session.id.uuidString]
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Whether the user allowed notifications, remembered from the launch
    /// prompt. Only gates the chime we play ourselves — everything Notification
    /// Center delivers is already gated by the system.
    private static var notificationsAuthorized = false

    /// Held for the app's lifetime: an NSSound stops if its object goes away
    /// mid-play, and this one is re-triggered rather than rebuilt each time.
    private static let turnDoneChime = NSSound(named: "Tink")

    /// "Your move" — quieter and clearly distinct from the alert ding, so the
    /// two are tellable apart from the next room. Restarted rather than
    /// overlapped when two agents finish at once.
    private static func playTurnDoneChime() {
        guard notificationsAuthorized, let chime = turnDoneChime else { return }
        chime.stop()
        chime.play()
    }

    /// Foreground delivery: still show the banner (the user is in another
    /// session, or away from the keyboard) — we only get here when the session
    /// isn't the actively-viewed one.
    // UNUserNotificationCenterDelegate requirements are nonisolated; marking the
    // implementations `nonisolated` keeps this @MainActor class's conformance from
    // crossing actor boundaries (a Swift 6 data-race error). Both callbacks are
    // delivered on the main thread, so the one that touches main-actor state hops
    // in synchronously via assumeIsolated.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the notification jumps to that session and brings Wortel front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            if let idString = response.notification.request.content.userInfo[Self.sessionKey] as? String,
               let id = UUID(uuidString: idString) {
                manager?.select(id: id)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
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

    /// ⌘⌥G — show, swap to, or close the source-control side of the inspector.
    /// It lands on whichever git pane was last chosen, so coming back from Files
    /// returns you to History if that's where you were.
    @objc func toggleSourceControl(_ sender: Any?) {
        gitPanel.activate(GitPanelModel.lastSourceControlPane)
    }

    /// ⌘⌥E — the same rule for the Files pane.
    @objc func toggleFileTree(_ sender: Any?) {
        gitPanel.activate(.files)
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
        // Each pane command reads "Hide" only when *its* pane is the one on
        // screen — with Files up, ⌘⌥G swaps rather than closes, so calling it
        // "Hide Source Control" would describe the wrong action.
        if menuItem.action == #selector(toggleSourceControl(_:)) {
            let showing = gitPanel.isVisible && gitPanel.pane.isSourceControl
            menuItem.title = showing ? "Hide Source Control" : "Show Source Control"
            return true
        }
        if menuItem.action == #selector(toggleFileTree(_:)) {
            let showing = gitPanel.isVisible && gitPanel.pane == .files
            menuItem.title = showing ? "Hide Files" : "Show Files"
            return true
        }
        // Only offer "Next Waiting Session" when something is actually waiting.
        if menuItem.action == #selector(selectNextAttentionSession(_:)) {
            return manager?.hasAttention ?? false
        }
        return true
    }
}
