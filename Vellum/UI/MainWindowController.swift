import AppKit

/// The single Vellum window: sidebar of sessions + terminal host.
/// Coordinates SessionManager <-> sidebar <-> host <-> store.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private let sessionManager: SessionManager
    private let store = SessionStore()

    private let sidebarVC = SidebarViewController()
    private let hostVC = TerminalHostViewController()
    private let splitVC = NSSplitViewController()

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        self.sessionManager = SessionManager(runtime: runtime)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Vellum"
        window.tabbingMode = .disallowed
        // No toolbar: the sidebar is one clean vibrant panel top-to-bottom and
        // the terminal runs full height. The transparent titlebar keeps the
        // traffic lights and provides a drag strip at the very top; combined
        // with isMovableByWindowBackground you can also drag by the sidebar's
        // empty area. Sidebar toggle = ⌘⌥S, New Session = ⌘T (both in menus).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        super.init(window: window)
        window.delegate = self

        // Split view: collapsible sidebar + terminal host.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitVC.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: hostVC)
        contentItem.minimumThickness = 320
        splitVC.addSplitViewItem(contentItem)
        splitVC.splitView.autosaveName = "split"

        // ORDER MATTERS: assigning contentViewController resizes the window
        // to the VC's preferred size (tiny, since plain NSViews have none).
        // Restore the autosaved frame AFTER, and reject degenerate frames
        // (an early bug saved a collapsed one).
        window.contentViewController = splitVC
        window.contentMinSize = NSSize(width: 500, height: 300)
        let restored = window.setFrameAutosaveName("main")
        if !restored || window.frame.height < 300 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }

        sessionManager.delegate = self
        sidebarVC.sessionProvider = { [weak self] in self?.sessionManager.sessions ?? [] }
        sidebarVC.onSelectRow = { [weak self] row in self?.sessionManager.select(index: row) }
        sidebarVC.onAddSession = { [weak self] in self?.sessionManager.newSession() }

        restoreSessions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Persistence

    private func restoreSessions() {
        let persisted = store.load()
        guard !persisted.isEmpty else {
            sessionManager.newSession()
            return
        }

        for entry in persisted {
            sessionManager.appendRestored(
                Session(id: entry.id, title: entry.title, cwd: entry.cwd))
        }
        let selectedIndex = persisted.firstIndex(where: \.selected) ?? 0

        // Only the selected session's shell spawns before first frame; the
        // rest warm up one per runloop turn shortly after.
        sessionManager.select(index: selectedIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sessionManager.warmRemainingSurfaces()
        }
    }

    private func persistedSessions() -> [PersistedSession] {
        let selected = sessionManager.selected
        return sessionManager.sessions.map {
            PersistedSession(id: $0.id, title: $0.title, cwd: $0.cwd, selected: $0 === selected)
        }
    }

    private func scheduleSave() {
        store.scheduleSave { [weak self] in self?.persistedSessions() ?? [] }
    }

    func saveSessionsNow() {
        store.saveNow(persistedSessions())
    }

    // MARK: - Menu actions (responder chain)

    @objc func newSession(_ sender: Any?) {
        sessionManager.newSession()
    }

    @objc func closeSession(_ sender: Any?) {
        sessionManager.closeSelected()
    }

    @objc func selectNextSession(_ sender: Any?) {
        sessionManager.selectNext()
    }

    @objc func selectPreviousSession(_ sender: Any?) {
        sessionManager.selectPrevious()
    }

    @objc func selectSessionAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        sessionManager.select(index: item.tag)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let currentView = hostVC.currentView else { return }
        window?.makeFirstResponder(currentView)
        currentView.focusDidChange(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        hostVC.currentView?.focusDidChange(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        hostVC.currentView?.occlusionDidChange(
            visible: window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        saveSessionsNow()
        for session in sessionManager.sessions {
            session.surfaceView?.close()
        }
    }
}

// MARK: - SessionManagerDelegate

extension MainWindowController: SessionManagerDelegate {
    func sessionManager(_ manager: SessionManager, didInsertSessionAt index: Int) {
        sidebarVC.insertRow(at: index)
        scheduleSave()
    }

    func sessionManager(_ manager: SessionManager, didRemoveSessionAt index: Int) {
        sidebarVC.removeRow(at: index)
        scheduleSave()
    }

    func sessionManager(_ manager: SessionManager, didUpdateSessionAt index: Int) {
        sidebarVC.reloadRow(at: index)
        if index == manager.selectedIndex, let session = manager.selected {
            updateWindowTitle(for: session)
        }
        scheduleSave()
    }

    func sessionManager(_ manager: SessionManager, didSelect session: Session, at index: Int) {
        sidebarVC.selectRow(at: index)
        hostVC.show(session, runtime: runtime)
        updateWindowTitle(for: session)
        scheduleSave()
    }

    /// Finder-like title bar: directory name as the title, abbreviated path
    /// as the subtitle.
    private func updateWindowTitle(for session: Session) {
        window?.title = session.displayName
        if let cwd = session.cwd, !cwd.isEmpty {
            window?.subtitle = (cwd as NSString).abbreviatingWithTildeInPath
        } else {
            window?.subtitle = ""
        }
    }

    func sessionManagerDidClose(_ manager: SessionManager) {
        // Last session closed -> quit (window close terminates the app).
        saveSessionsNow()
        close()
    }
}
