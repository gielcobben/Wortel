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

    // Title shown as a toolbar item on the CONTENT side (right of the sidebar
    // tracking separator) — the Opslan/NavigationSplitView look. Not the
    // window title, which always renders over the sidebar.
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

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
        // Opslan/Mail pattern: floating full-height sidebar; the session
        // name/path is a toolbar item on the content side (see the toolbar
        // delegate). The window title itself is hidden — it would render over
        // the sidebar, not next to it.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden

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

    /// Session name + path, shown in the content-side toolbar title item.
    private func updateWindowTitle(for session: Session) {
        titleLabel.stringValue = session.name
        subtitleLabel.stringValue = session.abbreviatedPath
        subtitleLabel.isHidden = session.abbreviatedPath.isEmpty
    }

    func sessionManagerDidClose(_ manager: SessionManager) {
        // Last session closed -> quit (window close terminates the app).
        saveSessionsNow()
        close()
    }
}

// MARK: - NSToolbarDelegate

private extension NSToolbarItem.Identifier {
    static let sessionTitle = NSToolbarItem.Identifier("sessionTitle")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Separator at the sidebar divider, then the title on the content side.
        [.sidebarTrackingSeparator, .sessionTitle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .sessionTitle]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarTrackingSeparator,
                splitView: splitVC.splitView,
                dividerIndex: 0)

        case .sessionTitle:
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingMiddle

            let stack = NSStackView(views: [titleLabel, subtitleLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0

            let item = NSToolbarItem(itemIdentifier: .sessionTitle)
            item.view = stack
            item.visibilityPriority = .high
            return item

        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }
}
