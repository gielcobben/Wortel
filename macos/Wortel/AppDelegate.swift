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
    /// Drives the Files pane — the third view of the same column. Reads the repo
    /// the git panel has already resolved, so it costs no extra git work.
    private lazy var fileTree = FileTreeModel(git: gitPanel)
    /// The preview windows. Accessories to the main window — they close with it,
    /// so quitting stays what it has always been.
    private lazy var previewWindows = PreviewWindows(highlighter: DiffHighlighter.shared)
    /// The `wortel` command's way in. Started once the session manager exists,
    /// since every command it serves is about a session.
    private var cli: WortelCLIService?
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
            runtime: runtime, manager: manager, git: gitPanel, files: fileTree)
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
        // Previews are accessories: without this, closing the last session would
        // leave a preview window standing, which both keeps the app alive (the
        // last window hasn't closed) and leaves a terminal with no terminal in it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.previewWindows.closeAll() }
        }
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
        // Everything that opens a file — a ⌘-clicked path in the terminal, a
        // double-clicked row in the tree, a Changes row, a file in a commit —
        // goes through one opener, so which diff a window shows is decided in
        // one place rather than four.
        manager.onOpenMarkdown = { [weak self] url in
            self?.openPreview(url)
        }
        fileTree.onOpenPreview = { [weak self] url in
            self?.openPreview(url)
        }
        gitPanel.onOpenPreview = { [weak self] url, diff, hasChanges in
            self?.previewWindows.open(url, diff: diff, hasChanges: hasChanges)
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
        // `.badge` is here for the **Dock badge**, which is drawn by us rather
        // than by Notification Center — `NSApp.dockTile.badgeLabel`. Once an app
        // registers with `UNUserNotificationCenter`, macOS gates that badge on
        // the same per-app "Badges" permission, so an app that asks only for
        // alerts and sounds can set `badgeLabel` all day and the Dock will
        // ignore it. Which is exactly what it was doing.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { Self.notificationsAuthorized = granted }
        }

        // Panel visibility and the chosen pane are session state, so a toggle has
        // to reach sessions.json.
        gitPanel.onStateChanged = { [weak manager] in manager?.sessionStateChanged() }

        // **Before any surface exists.** `GhosttyRuntime.keeper` is a lazy
        // static, and touching it for the first time from inside surface
        // creation means its initialiser runs while SwiftUI is mid-update — so
        // anything in it that lets the run loop turn can re-enter surface
        // creation and deadlock on its own `dispatch_once`. Doing it here makes
        // that impossible rather than merely unlikely.
        _ = GhosttyRuntime.keeper

        manager.restore()
        // Point the panel at the restored selection: it's what raises the panel
        // if that session had it up, and it seeds the cwd so the first toggle
        // resolves the right repo (no git work runs while it's hidden).
        gitPanel.focus(session: manager.selected)
        fileTree.focus(session: manager.selected)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Last, because everything it can be asked to do has to exist first.
        let cli = WortelCLIService(
            manager: manager,
            openPreview: { [weak self] url in self?.openPreview(url) },
            orderFront: { [weak self] in self?.window?.makeKeyAndOrderFront(nil) })
        cli.start()
        self.cli = cli

        observeWindowTitle()
    }

    /// The toolbar is retained here because NSWindow doesn't own its delegate.
    private var toolbarDelegate: MainToolbarDelegate?

    private func installToolbar(on window: NSWindow, splitView: NSSplitView) {
        let delegate = MainToolbarDelegate(splitView: splitView, git: gitPanel)
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

    // MARK: - Focus tracking (drives "actively viewing" → no attention shout)

    func applicationDidBecomeActive(_ notification: Notification) {
        manager?.appDidBecomeActive()
        // Whatever happened to the work tree while we were away — a branch
        // switched in another window, a build run from another terminal — the
        // file tree's watchers may not have been able to see it. Coming back is
        // the natural moment to re-read what's open. No-ops unless the tree is
        // the pane on screen.
        fileTree.resync()
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
        // Which session this is about, always. When the program authored the
        // notification the title is its own ("Codex", "Waiting for Approval")
        // and named no session at all, which leaves the banner indistinguishable
        // from one raised by any other session running the same agent.
        if title != session.name { content.subtitle = session.name }
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
        // The socket's name is a file, and it outlives the process that made
        // it. The server recovers from a stale one on the next launch, but only
        // by proving it's stale — cheaper and less alarming to tidy up.
        cli?.stop()
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

    // MARK: - Preview windows

    /// Open a file in a preview window, working out what its diff should be.
    ///
    /// A file the repo already knows is changed opens on *its* row's diff, which
    /// is what the Changes pane would have shown; anything else in a repo gets
    /// everything since HEAD, because that's the question you're asking when you
    /// point at a file rather than at one side of its change. Outside a repo
    /// there's no diff to offer and the window says so by not having the mode.
    /// Repo root per directory. The answer never changes for a given directory
    /// in a session, and asking git twice for the same one is a process we
    /// don't need to spawn.
    private var repoRootCache: [String: String?] = [:]

    /// Open a file in a preview window, working out what its diff should be.
    ///
    /// Deliberately **not** dependent on the git panel being open. The panel
    /// resolves its repo only while it's visible — a good rule for a panel that
    /// would otherwise run git for a column nobody is looking at, and exactly
    /// the wrong one here: it meant a file opened with the inspector closed had
    /// no repo, so no diff source, so no Diff mode at all. When the panel
    /// happens to have the answer it's free; when it doesn't, we ask.
    private func openPreview(_ requested: URL) {
        // Two paths, deliberately: git and the window registry work on the real
        // file, while the window is opened with the path you actually clicked so
        // it can tell you when that was an alias.
        let url = requested.resolvingSymlinksInPath().standardizedFileURL
        // Already open: focus it and do no git work whatsoever.
        if previewWindows.focus(url) { return }

        // The panel already knows this repo and its status — free, and it also
        // knows *which side* of a change the file is on.
        if let repo = gitPanel.repo, let relative = Self.relativePath(of: url, in: repo.root) {
            let change = repo.status.unstagedChanges.first { $0.path == relative }
                ?? repo.status.stagedChanges.first { $0.path == relative }
            if let change {
                previewWindows.open(requested, diff: .change(root: repo.root, change: change),
                                    hasChanges: true)
            } else {
                previewWindows.open(
                    requested,
                    diff: .workingTree(root: repo.root, path: relative, untracked: false))
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let directory = url.deletingLastPathComponent().path
            let root: String?
            if let cached = repoRootCache[directory] {
                root = cached
            } else {
                root = await GitService.repoRoot(for: directory)
                repoRootCache[directory] = root
            }
            guard let root, let relative = Self.relativePath(of: url, in: root) else {
                previewWindows.open(requested)
                return
            }
            // One line of porcelain, not a patch: it decides whether the window
            // opens on the diff or on the file, and whether that diff is against
            // HEAD or against nothing at all.
            let state = await GitService.workingTreeState(root: root, path: relative)
            previewWindows.open(
                requested,
                diff: .workingTree(root: root, path: relative, untracked: state == .untracked),
                hasChanges: state.hasChanges)
        }
    }

    private static func relativePath(of url: URL, in root: String) -> String? {
        let path = url.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Menu actions (reached via the responder chain, target nil)

    /// Every command below acts on the session list, which lives in the main
    /// window — and the menu's key equivalents fire wherever you are. With a
    /// preview window key that means ⌘N would open a session behind the window
    /// you're looking at, and ⌘R would start an inline rename in a sidebar you
    /// can't see. So a session command brings its own window forward first.
    ///
    /// ⌘W is the exception and gets its own handling: it closes what you're
    /// looking at.
    private func focusMainWindow() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    @objc func newSession(_ sender: Any?) {
        focusMainWindow()
        manager.newSession()
    }

    @objc func newSection(_ sender: Any?) {
        focusMainWindow()
        if let name = promptFolderName(title: "New Section", confirm: "Create") {
            manager.addFolder(named: name)
        }
    }

    /// ⌘W closes **what you are looking at**. With a preview window key that is
    /// the preview — closing a session from a file window is destructive, and no
    /// Mac app does that with ⌘W. The menu item says "Close Session" because
    /// that is what it does in the window it belongs to.
    @objc func closeSession(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(sender)
            return
        }
        manager.requestCloseSelected()
    }

    @objc func renameSession(_ sender: Any?) {
        focusMainWindow()
        manager.beginRenameSelected()
    }

    @objc func selectNextSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectNext()
    }

    @objc func selectPreviousSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectPrevious()
    }

    @objc func selectNextAttentionSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectNextAttention()
    }

    @objc func selectSessionAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        focusMainWindow()
        manager.select(index: item.tag)
    }

    /// ⌘⌥G — show, swap to, or close the source-control side of the inspector.
    /// It lands on whichever git pane was last chosen, so coming back from Files
    /// returns you to History if that's where you were.
    @objc func toggleSourceControl(_ sender: Any?) {
        focusMainWindow()
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
