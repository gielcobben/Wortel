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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Vellum"
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        // A unified toolbar makes AppKit give the split view's sidebar item the
        // system's native sidebar treatment — the floating/inset translucent
        // panel (Liquid Glass on macOS 26). We don't reproduce this by hand.
        window.toolbarStyle = .unified

        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitVC.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: hostVC)
        contentItem.minimumThickness = 360
        splitVC.addSplitViewItem(contentItem)
        splitVC.splitView.autosaveName = "split"

        window.contentViewController = splitVC
        window.contentMinSize = NSSize(width: 560, height: 320)
        let restored = window.setFrameAutosaveName("main")
        if !restored || window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }

        // Empty toolbar: no items, no separator — invisible, but enables the
        // native sidebar treatment.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar

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
                Session(id: entry.id, name: entry.name, title: entry.title, cwd: entry.cwd))
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
            PersistedSession(id: $0.id, name: $0.name, title: $0.title, cwd: $0.cwd, selected: $0 === selected)
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

    /// Session name as the window title, abbreviated path as the subtitle.
    private func updateWindowTitle(for session: Session) {
        window?.title = session.name
        window?.subtitle = session.abbreviatedPath
    }

    func sessionManagerDidClose(_ manager: SessionManager) {
        // Last session closed -> quit (window close terminates the app).
        saveSessionsNow()
        close()
    }
}

// MARK: - NSToolbarDelegate (empty toolbar, present only for the native sidebar)

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
}
