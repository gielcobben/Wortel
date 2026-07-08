import AppKit
import Observation

/// Owns the session list, selection, and persistence. `@Observable` so the
/// SwiftUI shell (NavigationSplitView) reflects changes automatically — no
/// delegate. Main thread only.
@Observable
@MainActor
final class SessionManager {
    @ObservationIgnored private let runtime: GhosttyRuntime
    @ObservationIgnored private let store = SessionStore()

    private(set) var sessions: [Session] = []

    /// Bound to the sidebar List's selection. `didSet` lazily creates the
    /// selected session's surface and clears its bell — so both user clicks
    /// and programmatic selection (menu shortcuts) go through one path.
    var selectedID: Session.ID? {
        didSet {
            guard selectedID != oldValue, let session = selected else { return }
            if session.hasBell { session.hasBell = false }
            session.ensureSurfaceView(runtime: runtime)
            scheduleSave()
        }
    }

    /// The session whose name is being edited inline (nil = none). Observed by
    /// the sidebar so double-click, the context menu, and ⌘R all drive one path.
    var editingID: Session.ID?

    /// Called when the last session closes (the window should close).
    @ObservationIgnored var onAllClosed: (() -> Void)?

    @ObservationIgnored private var sessionCounter = 0

    var selected: Session? {
        sessions.first { $0.id == selectedID }
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
    }

    // MARK: - Restore

    /// Restore persisted sessions (or create the first). Only the selected
    /// session's shell spawns before the first frame; the rest warm up shortly
    /// after so launch stays lean.
    func restore() {
        let persisted = store.load()
        guard !persisted.isEmpty else {
            newSession()
            return
        }
        for entry in persisted {
            appendRestored(Session(id: entry.id, name: entry.name, title: entry.title, cwd: entry.cwd))
        }
        selectedID = (persisted.first(where: \.selected) ?? persisted[0]).id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.warmRemainingSurfaces()
        }
    }

    // MARK: - Operations

    /// Create a session and select it; new sessions inherit the current
    /// working directory.
    @discardableResult
    func newSession(cwd: String? = nil) -> Session {
        sessionCounter += 1
        let session = Session(name: "Session \(sessionCounter)", cwd: cwd ?? selected?.cwd)
        session.title = Self.defaultTitle(forCwd: session.cwd)
        wire(session)
        sessions.append(session)
        selectedID = session.id
        scheduleSave()
        return session
    }

    private func appendRestored(_ session: Session) {
        // Keep the default-name counter ahead of any restored "Session N".
        if let n = Self.sessionNumber(from: session.name) {
            sessionCounter = max(sessionCounter, n)
        }
        wire(session)
        sessions.append(session)
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasSelected = session.id == selectedID
        session.close()
        sessions.remove(at: index)

        guard !sessions.isEmpty else {
            selectedID = nil
            saveNow()
            onAllClosed?()
            return
        }

        if wasSelected {
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
        scheduleSave()
    }

    func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        session.name = trimmed
        scheduleSave()
    }

    /// Begin inline-renaming the selected session (⌘R / menu).
    func beginRenameSelected() {
        editingID = selectedID
    }

    /// Drag-to-reorder from the sidebar. Selection (by id) and live surfaces
    /// are unaffected — only the array order changes.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        sessions.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleSave()
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    func selectNext() {
        guard let i = selectedIndex, sessions.count > 1 else { return }
        selectedID = sessions[(i + 1) % sessions.count].id
    }

    func selectPrevious() {
        guard let i = selectedIndex, sessions.count > 1 else { return }
        selectedID = sessions[(i - 1 + sessions.count) % sessions.count].id
    }

    private var selectedIndex: Int? {
        sessions.firstIndex { $0.id == selectedID }
    }

    /// Create surfaces for restored sessions that don't have one yet, one per
    /// runloop turn, so every session is warm within a couple of seconds.
    func warmRemainingSurfaces(limit: Int = 20) {
        guard limit > 0, let cold = sessions.first(where: { $0.surfaceView == nil }) else { return }
        cold.ensureSurfaceView(runtime: runtime)
        DispatchQueue.main.async { [weak self] in
            self?.warmRemainingSurfaces(limit: limit - 1)
        }
    }

    // MARK: - Persistence

    private func persistedSessions() -> [PersistedSession] {
        sessions.map {
            PersistedSession(id: $0.id, name: $0.name, title: $0.title, cwd: $0.cwd,
                             selected: $0.id == selectedID)
        }
    }

    private func scheduleSave() {
        store.scheduleSave { [weak self] in self?.persistedSessions() ?? [] }
    }

    func saveNow() {
        store.saveNow(persistedSessions())
    }

    // MARK: - Wiring

    private func wire(_ session: Session) {
        let id = session.id
        session.onSurfaceCreated = { [weak self, weak session] view in
            guard let self, let session else { return }

            view.onTitleChange = { [weak session] title in
                // Recorded but not displayed; bursty, so no save/UI churn.
                session?.title = title
            }
            view.onPwdChange = { [weak self, weak session] pwd in
                guard let self, let session else { return }
                session.cwd = pwd // observed → sidebar row + navigation subtitle update
                self.scheduleSave()
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session, session.id != self.selectedID else { return }
                session.hasBell = true // observed → sidebar badge
            }
            view.onCloseRequest = { [weak self] in
                guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
                self.close(session)
            }
        }
    }

    static func defaultTitle(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    private static func sessionNumber(from name: String) -> Int? {
        let prefix = "Session "
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}
