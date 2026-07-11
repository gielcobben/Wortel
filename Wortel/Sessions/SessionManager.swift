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
            clearAttention(session)
            session.ensureSurfaceView(runtime: runtime)
            scheduleSave()
        }
    }

    /// The session whose name is being edited inline (nil = none). Observed by
    /// the sidebar so double-click, the context menu, and ⌘R all drive one path.
    var editingID: Session.ID?

    /// Called when the last session closes (the window should close).
    @ObservationIgnored var onAllClosed: (() -> Void)?

    /// Presents a modal confirmation for closing a session that still has a
    /// running process, calling back with `true` to proceed. Set by the app
    /// layer (it owns the window to sheet onto). When nil, closes without
    /// asking.
    @ObservationIgnored var confirmClose: ((Session, @escaping (Bool) -> Void) -> Void)?

    /// A background session raised attention (a program asked for you — e.g.
    /// Claude Code emits OSC 777 on a permission/idle prompt, or a bell). The
    /// app layer turns this into a native macOS notification. `title`/`body`
    /// come from the program when it's a notification, or are synthesized.
    @ObservationIgnored var onNeedsAttention: ((Session, _ title: String, _ body: String) -> Void)?

    /// A session's attention was answered (selected / app came front / closed).
    /// The app layer uses this to retract the session's notification from
    /// Notification Center so stale "needs you" banners don't linger.
    @ObservationIgnored var onAttentionCleared: ((Session) -> Void)?

    /// Whether Wortel is the frontmost app. A session the user is *actively
    /// viewing* (app active + window visible + selected) never raises
    /// attention — they can see it. Set by the app layer on activate/resign.
    @ObservationIgnored var appIsActive = true

    /// Whether the main window is actually on screen (not miniaturized or
    /// fully occluded). An active app with a minimized window is *not*
    /// "actively viewing" anything. Set by the app layer on occlusion changes.
    @ObservationIgnored var windowIsVisible = true

    @ObservationIgnored private var sessionCounter = 0

    /// Busy is shown only after a command has been running this long, so
    /// instant commands (ls, cd, git status) never flash the spinner.
    private static let busyShowDelay: TimeInterval = 0.15
    /// A command that ran at least this long and finished while its session was
    /// unselected raises the attention dot.
    private static let attentionAfterNs: UInt64 = 10_000_000_000 // 10s
    /// After a progress-emitting program (an agent like Claude Code) reports it
    /// stopped working (OSC 9;4;0), wait this long before raising attention —
    /// if progress resumes in the window (a blip between tools), it's cancelled.
    private static let quiesceSettleDelay: TimeInterval = 1.0
    /// Progress must have been active at least this long for its end to mean
    /// "the agent wants you"; shorter blips are noise, not a finished turn.
    private static let minBusyForQuiesceAttention: TimeInterval = 2.0
    /// Pending "show busy" work items, keyed by session; cancelled if the
    /// command finishes before the delay elapses.
    @ObservationIgnored private var busyTimers: [Session.ID: DispatchWorkItem] = [:]
    /// Pending "agent stopped → raise attention" work items, keyed by session;
    /// cancelled if progress resumes first.
    @ObservationIgnored private var quiesceTimers: [Session.ID: DispatchWorkItem] = [:]
    /// When each session's busy spinner actually turned on; drives the
    /// minimum-duration gate above.
    @ObservationIgnored private var busyStartedAt: [Session.ID: Date] = [:]
    /// The last (start, cleared) busy interval per session. If busy re-arms
    /// shortly after clearing, it's a continuation of the same run of work —
    /// e.g. Pi's OSC 133 zone marks make the core synthesize a command-finished
    /// mid-turn, then its 1s progress keepalive re-marks busy — so the original
    /// start is restored to keep the duration gate honest.
    @ObservationIgnored private var lastBusyInterval: [Session.ID: (start: Date, cleared: Date)] = [:]
    /// Re-arming busy within this window of the last clear counts as a
    /// continuation (see `lastBusyInterval`).
    private static let busyContinuationWindow: TimeInterval = 3.0
    /// Sessions whose terminal title currently shows a "working" marker
    /// (see `titleChanged`).
    @ObservationIgnored private var titleShowsWorking: Set<Session.ID> = []

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
        let hadAttention = session.needsAttention
        busyTimers.removeValue(forKey: session.id)?.cancel()
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        busyStartedAt.removeValue(forKey: session.id)
        lastBusyInterval.removeValue(forKey: session.id)
        titleShowsWorking.remove(session.id)
        session.close()
        sessions.remove(at: index)
        if hadAttention { refreshDockBadge() }
        // Retract any notification still sitting in Notification Center for a
        // session that no longer exists.
        onAttentionCleared?(session)

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

    /// Interactive close (menu / context menu / ⌘W): confirms first if the
    /// session still has a running process, otherwise closes immediately.
    func requestClose(_ session: Session) {
        guard session.needsConfirmClose, let confirmClose else {
            close(session)
            return
        }
        confirmClose(session) { [weak self] proceed in
            guard proceed else { return }
            // Re-check membership: the sheet is async, the session may have
            // gone away (e.g. the shell exited while it was open).
            guard let self, self.sessions.contains(where: { $0.id == session.id }) else { return }
            self.close(session)
        }
    }

    func requestCloseSelected() {
        guard let selected else { return }
        requestClose(selected)
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

    /// Select a session by id (e.g. from tapping its attention notification).
    func select(id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
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

    // MARK: - Busy state (debounced)

    /// A command started: show busy after a short delay so instant commands
    /// don't flicker. Coalesces repeat progress reports for a running command.
    /// Also cancels a pending quiesce-attention: the program resumed working,
    /// so its earlier "stopped" was a blip, not a prompt for the user.
    private func markBusy(_ session: Session) {
        quiesceTimers.removeValue(forKey: session.id)?.cancel()
        guard busyTimers[session.id] == nil, !session.isBusy else { return }
        let id = session.id
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.busyTimers[id] = nil
            let now = Date()
            if let last = self.lastBusyInterval[id],
               now.timeIntervalSince(last.cleared) < Self.busyContinuationWindow {
                self.busyStartedAt[id] = last.start // continuation, not a new run
            } else {
                self.busyStartedAt[id] = now
            }
            session.isBusy = true
        }
        busyTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyShowDelay, execute: work)
    }

    /// A command finished (or progress was cleared): cancel any pending show
    /// and drop busy immediately.
    private func clearBusy(_ session: Session) {
        busyTimers.removeValue(forKey: session.id)?.cancel()
        if let start = busyStartedAt.removeValue(forKey: session.id) {
            lastBusyInterval[session.id] = (start: start, cleared: Date())
        }
        if session.isBusy { session.isBusy = false }
    }

    /// Title-marker fallback for agents that signal state only through the
    /// window title. Verified conventions: Claude Code and Codex animate a
    /// braille spinner (U+2800…U+28FF) while working; Gemini CLI uses
    /// "✦/⏲ Working", "◇ Ready", and "✋ Action Required"; Codex prefixes
    /// "[ ! ] Action Required" when blocked on the user. Marker appearing →
    /// busy; marker disappearing → same quiesce machinery as OSC 9;4; explicit
    /// action-required marker → attention right away. For agents that also
    /// emit real progress (Claude Code) the two paths agree: the title spinner
    /// stops at the same moment 9;4;0 arrives.
    private func titleChanged(_ session: Session, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let wasWorking = titleShowsWorking.contains(session.id)
        if trimmed.hasPrefix("✋") || trimmed.contains("Action Required") {
            titleShowsWorking.remove(session.id)
            clearBusy(session)
            raiseAttention(session, title: session.name, body: "Action required")
        } else if Self.hasWorkingMarker(trimmed) {
            titleShowsWorking.insert(session.id)
            markBusy(session)
        } else if wasWorking {
            titleShowsWorking.remove(session.id)
            progressEnded(session)
        }
    }

    private static func hasWorkingMarker(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return first == "✦" || first == "⏲" || (0x2800...0x28FF).contains(first.value)
    }

    /// A progress-emitting program reported it stopped working (OSC 9;4;0).
    /// For agent CLIs (Claude Code, etc.) this is the *only* reliable "I need
    /// you now" signal — they emit it at permission prompts and at turn end,
    /// but send no bell or desktop notification under Ghostty. So: if the
    /// session was visibly busy long enough, raise attention after a short
    /// settle window (cancelled if progress resumes or a prompt returns).
    private func progressEnded(_ session: Session) {
        let busyLongEnough = busyStartedAt[session.id].map {
            Date().timeIntervalSince($0) >= Self.minBusyForQuiesceAttention
        } ?? false
        clearBusy(session)
        guard busyLongEnough else { return }
        let id = session.id
        quiesceTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.quiesceTimers[id] = nil
            self.raiseAttention(session, title: session.name, body: "Ready for your input")
        }
        quiesceTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiesceSettleDelay, execute: work)
    }

    // MARK: - Attention

    /// The user can already see this session (Wortel is frontmost, the window
    /// is on screen, and the session is selected), so it never needs to shout
    /// for attention.
    private func isActivelyViewing(_ session: Session) -> Bool {
        appIsActive && windowIsVisible && session.id == selectedID
    }

    /// Attention answered: drop the sidebar dot, re-count the Dock badge, and
    /// let the app layer retract the session's notification.
    private func clearAttention(_ session: Session) {
        guard session.needsAttention else { return }
        session.needsAttention = false
        refreshDockBadge()
        onAttentionCleared?(session)
    }

    /// A session wants the user: raise the sidebar dot (which overrides the
    /// busy spinner), badge the Dock, and post a native notification — unless
    /// the user is already looking at it. Safe to call repeatedly; the app
    /// layer keys notifications by session so they replace, not stack.
    private func raiseAttention(_ session: Session, title: String, body: String) {
        guard !isActivelyViewing(session) else { return }
        session.needsAttention = true // observed → sidebar dot
        refreshDockBadge()
        onNeedsAttention?(session, title, body)
    }

    /// Wortel became frontmost: the user is now looking at the selected
    /// session, so clear its attention.
    func appDidBecomeActive() {
        appIsActive = true
        if let selected { clearAttention(selected) }
    }

    func appDidResignActive() {
        appIsActive = false
    }

    /// The main window's on-screen visibility changed (occlusion state /
    /// miniaturization). Becoming visible while frontmost means the user can
    /// now see the selected session — clear its attention, same as activate.
    func windowVisibilityChanged(_ visible: Bool) {
        windowIsVisible = visible
        if visible, appIsActive, let selected { clearAttention(selected) }
    }

    /// Dock badge = number of background sessions waiting on the user.
    private func refreshDockBadge() {
        let count = sessions.reduce(into: 0) { $0 += $1.needsAttention ? 1 : 0 }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
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

            view.onTitleChange = { [weak self, weak session] title in
                guard let self, let session else { return }
                // Recorded but not displayed; bursty, so no save/UI churn.
                session.title = title
                self.titleChanged(session, title: title)
            }
            view.onPwdChange = { [weak self, weak session] pwd in
                guard let self, let session else { return }
                session.cwd = pwd // observed → sidebar row + navigation subtitle update
                self.scheduleSave()
            }
            view.onBell = { [weak self, weak session] in
                guard let self, let session else { return }
                self.raiseAttention(session, title: session.name, body: "Bell")
            }
            view.onProgress = { [weak self, weak session] active in
                guard let self, let session else { return }
                if active { self.markBusy(session) } else { self.progressEnded(session) }
            }
            view.onCommandFinished = { [weak self, weak session] _, durationNs in
                guard let self, let session else { return }
                // Note: deliberately does NOT cancel a pending quiesce raise.
                // Pi's OSC 133 zone marks synthesize finished events mid-turn;
                // cancelling here would eat the legit "agent is done" attention
                // that a 9;4;0 just scheduled. A duplicate raise is harmless —
                // notifications are keyed per session and replace.
                self.clearBusy(session)
                // A long command that finished while you were elsewhere wants
                // your eyes (e.g. an agent that ran for a while and is done).
                if durationNs >= Self.attentionAfterNs {
                    self.raiseAttention(session, title: session.name, body: "Command finished")
                }
            }
            view.onNotification = { [weak self, weak session] title, body in
                guard let self, let session else { return }
                // Program-authored "needs you" (OSC 9/777/99) — e.g. Claude Code
                // on a permission or idle prompt. The most reliable signal.
                self.raiseAttention(session,
                                    title: title.isEmpty ? session.name : title,
                                    body: body)
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
