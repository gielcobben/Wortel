import AppKit

/// The single Vellum window: sidebar of sessions + terminal host.
/// Coordinates SessionManager <-> sidebar <-> host <-> store.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private let sessionManager: SessionManager
    private let store = SessionStore()

    private let sidebarVC = SidebarViewController()
    private let hostVC = TerminalHostViewController()

    /// The vibrant sidebar panel. Built by hand (rather than via
    /// NSSplitViewController) so it reliably fills the full window height —
    /// including behind the traffic lights, so they sit ON the sidebar like
    /// Finder.
    private let sidebarEffect = NSVisualEffectView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var expandedSidebarWidth: CGFloat = 250

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
        // fullSizeContentView + transparent titlebar so the content fills the
        // full window; the vibrant sidebar below runs to the very top and the
        // traffic lights float over it (Finder). Drag via the top strip or the
        // sidebar's empty area.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        super.init(window: window)
        window.delegate = self

        // --- Manual sidebar + terminal layout, both pinned to the top --------
        let root = NSView()

        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .followsWindowActiveState
        sidebarEffect.translatesAutoresizingMaskIntoConstraints = false

        let sidebarContent = sidebarVC.view
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        sidebarEffect.addSubview(sidebarContent)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let terminal = hostVC.view
        terminal.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebarEffect)
        root.addSubview(divider)
        root.addSubview(terminal)

        sidebarWidthConstraint = sidebarEffect.widthAnchor.constraint(equalToConstant: expandedSidebarWidth)

        NSLayoutConstraint.activate([
            sidebarEffect.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEffect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidthConstraint,

            sidebarContent.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebarContent.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebarContent.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sidebarContent.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            terminal.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: root.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
        window.contentMinSize = NSSize(width: 520, height: 320)
        let restored = window.setFrameAutosaveName("main")
        if !restored || window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }

        sessionManager.delegate = self
        sidebarVC.sessionProvider = { [weak self] in self?.sessionManager.sessions ?? [] }
        sidebarVC.onSelectRow = { [weak self] row in self?.sessionManager.select(index: row) }
        sidebarVC.onAddSession = { [weak self] in self?.sessionManager.newSession() }

        restoreSessions()
    }

    // MARK: - Sidebar toggle (⌘⌥S / menu)

    @objc func toggleSidebar(_ sender: Any?) {
        let collapsed = sidebarWidthConstraint.constant < 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidthConstraint.animator().constant = collapsed ? expandedSidebarWidth : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }
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
