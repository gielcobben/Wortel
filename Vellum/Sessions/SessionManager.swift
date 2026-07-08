import AppKit

@MainActor
protocol SessionManagerDelegate: AnyObject {
    func sessionManager(_ manager: SessionManager, didInsertSessionAt index: Int)
    func sessionManager(_ manager: SessionManager, didRemoveSessionAt index: Int)
    func sessionManager(_ manager: SessionManager, didUpdateSessionAt index: Int)
    /// Fired after `selected` changed. The delegate shows the session's view
    /// and moves first responder.
    func sessionManager(_ manager: SessionManager, didSelect session: Session, at index: Int)
    /// Last session closed.
    func sessionManagerDidClose(_ manager: SessionManager)
}

/// Owns the session list and selection. Pure model + surface lifecycle;
/// all UI flows through the delegate. Main thread only.
@MainActor
final class SessionManager {
    private let runtime: GhosttyRuntime
    weak var delegate: SessionManagerDelegate?

    private(set) var sessions: [Session] = []
    private(set) var selectedIndex: Int = -1

    var selected: Session? {
        guard sessions.indices.contains(selectedIndex) else { return nil }
        return sessions[selectedIndex]
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
    }

    // MARK: - Operations

    /// Create a session and select it. New sessions inherit the current
    /// session's working directory when none is given.
    @discardableResult
    func newSession(cwd: String? = nil) -> Session {
        let session = Session(cwd: cwd ?? selected?.cwd)
        session.title = Self.defaultTitle(forCwd: session.cwd)
        wire(session)
        sessions.append(session)
        delegate?.sessionManager(self, didInsertSessionAt: sessions.count - 1)
        select(index: sessions.count - 1)
        return session
    }

    /// Append a restored session without selecting or creating its surface.
    func appendRestored(_ session: Session) {
        wire(session)
        sessions.append(session)
        delegate?.sessionManager(self, didInsertSessionAt: sessions.count - 1)
    }

    func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.close()
        sessions.remove(at: index)
        delegate?.sessionManager(self, didRemoveSessionAt: index)

        guard !sessions.isEmpty else {
            selectedIndex = -1
            delegate?.sessionManagerDidClose(self)
            return
        }

        // Keep selection sensible: prefer the session that took this slot's
        // place, else the new last one.
        let newIndex = min(index, sessions.count - 1)
        selectedIndex = -1 // force reselect even if the number didn't change
        select(index: newIndex)
    }

    func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    func select(index: Int) {
        guard sessions.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        let session = sessions[index]
        if session.hasBell {
            session.hasBell = false
            delegate?.sessionManager(self, didUpdateSessionAt: index)
        }
        session.ensureSurfaceView(runtime: runtime)
        delegate?.sessionManager(self, didSelect: session, at: index)
    }

    func selectNext() {
        guard sessions.count > 1 else { return }
        select(index: (selectedIndex + 1) % sessions.count)
    }

    func selectPrevious() {
        guard sessions.count > 1 else { return }
        select(index: (selectedIndex - 1 + sessions.count) % sessions.count)
    }

    /// Create surfaces for restored sessions that don't have one yet, one
    /// per runloop turn, so launch stays lean but every session is warm
    /// within a couple of seconds.
    func warmRemainingSurfaces(limit: Int = 20) {
        let cold = sessions.filter { $0.surfaceView == nil }.prefix(limit)
        guard let first = cold.first else { return }
        first.ensureSurfaceView(runtime: runtime)
        delegate?.sessionManager(self, didUpdateSessionAt: sessions.firstIndex { $0.id == first.id } ?? 0)
        if cold.count > 1 {
            DispatchQueue.main.async { [weak self] in
                self?.warmRemainingSurfaces(limit: limit - 1)
            }
        }
    }

    // MARK: - Wiring

    private func wire(_ session: Session) {
        let id = session.id

        session.onSurfaceCreated = { [weak self, weak session] view in
            guard let self, let session else { return }

            view.onTitleChange = { [weak self, weak session] title in
                guard let self, let session,
                      let index = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                session.title = title
                self.delegate?.sessionManager(self, didUpdateSessionAt: index)
            }
            view.onPwdChange = { [weak session] pwd in
                session?.cwd = pwd
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session,
                      let index = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                guard session !== self.selected else { return }
                session.hasBell = true
                self.delegate?.sessionManager(self, didUpdateSessionAt: index)
            }
            view.onCloseRequest = { [weak self] in
                guard let self,
                      let session = self.sessions.first(where: { $0.id == id }) else { return }
                self.close(session)
            }
        }
    }

    static func defaultTitle(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }
}
