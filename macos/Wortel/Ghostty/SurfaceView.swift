// Portions of this file are ported from Ghostty.app (SurfaceView_AppKit.swift,
// Ghostty v1.3.1, https://github.com/ghostty-org/ghostty):
//
//     Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//     MIT License. The full notice is in THIRD-PARTY-NOTICES.md.
//
// Wortel's changes and additions are GPL-3.0-or-later, like the rest of
// Wortel (LICENSE).

import AppKit
import GhosttyKit
import IOSurface
import os

/// A terminal found at a size that is not its view's, and put right.
///
///     log show --last 1h --predicate 'subsystem == "com.gielcobben.Wortel" && category == "layout"'
enum LayoutLog {
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "layout")
}

/// The NSView hosting one ghostty surface (one terminal). Ported from
/// Ghostty.app's SurfaceView_AppKit.swift (v1.3.1), trimmed to Wortel's
/// scope: no splits, no drag/drop, no inspector, no context menu.
///
/// The Zig core installs its own IOSurface-backed CALayer on this view
/// (it sets `wantsLayer` and `layer` itself) and renders from its own
/// thread. This view's only jobs are input forwarding and geometry.
final class SurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    private weak var runtime: GhosttyRuntime?

    // Session-facing callbacks, set by the owner (window controller /
    // session manager). Always invoked on the main thread.
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    /// A foreground command's progress state changed (OSC 9;4). `active` is
    /// true while a command is running (set / indeterminate / error), false
    /// when cleared or paused; `errored` is true for the error state, which is
    /// still running but has said it is failing. Drives the per-session busy
    /// indicator; the start edge comes from the bundled shell integration's
    /// preexec hook.
    var onProgress: ((_ active: Bool, _ errored: Bool) -> Void)?
    /// The running command finished (OSC 133;D). `exitCode` is -1 if unknown;
    /// `durationNs` is how long it ran, in nanoseconds. Authoritative "idle".
    var onCommandFinished: ((_ exitCode: Int, _ durationNs: UInt64) -> Void)?
    /// The program asked for a desktop notification (OSC 9 / 777 / 99).
    /// `replayed`: it asked while nobody was attached, so it is old news.
    var onNotification: ((_ title: String, _ body: String, _ replayed: Bool) -> Void)?
    /// The program reported what it is doing (OSC 7501, `ProgramStatus`): the
    /// one signal that is its own word and not a reading of its screen.
    /// `replayed`: read from what it wrote while nobody was attached, so it is
    /// what is true now, not something that just happened.
    var onProgramStatus: ((_ report: ProgramStatusReport, _ replayed: Bool) -> Void)?
    /// A ⌘-click that may be on a link: what libghostty matched there
    /// (`GhosttyRuntime`'s OPEN_URL handler), and the rows around it, for a
    /// link an agent broke over several rows (`TerminalLinkWrap`). The owner
    /// decides what it is and opens it (`SessionManager.openLink`).
    var onOpenLink: ((_ request: TerminalLinkRequest) -> Void)?

    /// libghostty found a link under a click (OPEN_URL). The click's rows go
    /// with it, if this was the ⌘-click just released.
    func openLink(_ link: String, tagged: Bool) {
        let click = pendingLinkClick
        pendingLinkClick = nil
        onOpenLink?(TerminalLinkRequest(link: link, tagged: tagged, click: click))
    }
    /// The folder the shell last reported (OSC 7), for resolving a relative
    /// path clicked in this terminal. A side terminal's own: the session's
    /// `cwd` follows its main shell only.
    private(set) var reportedPwd: String?

    func reportPwd(_ pwd: String) {
        reportedPwd = pwd
        onPwdChange?(pwd)
    }
    /// The surface was resized, so its content re-wrapped. Fires for every
    /// session, not just the visible one — they all autoresize with the window.
    /// The agent-activity sampler listens so a reflow isn't read as work.
    var onSizeChange: (() -> Void)?
    /// The user sent something to this surface — a key, pasted or dropped
    /// text, a mouse press, a scroll. Whatever the screen does next is their
    /// doing, not the program's. The agent-activity sampler listens so that
    /// typing a prompt into a TUI is never read as the agent working.
    var onUserInput: (() -> Void)?
    /// When the user last sent something here, by those same events rather
    /// than the bytes the program gets, which also carry the terminal's
    /// replies to its queries. `wortel wait --idle` counts it as the session
    /// being touched.
    private(set) var lastUserInputAt: Date?
    /// Text or a Return a script sent (`wortel send`, `scripted: true`): it
    /// reaches the pty by the same road as the user's, so the input taps
    /// (`PromptTap`) see it as they see typing, but it
    /// is **not the user**. It doesn't answer an attention raised while they
    /// were away, and it doesn't move `lastUserInputAt`: an agent driving a
    /// session from elsewhere is not someone back at the keyboard. The
    /// screen it changes is still not the program's doing, which is all
    /// this hook is for (the activity sampler re-baselines on it).
    var onScriptedInput: (() -> Void)?
    /// When a script last sent something here, for `wortel wait --idle`,
    /// whose quiet after a `send` means "not started yet".
    private(set) var lastScriptedInputAt: Date?
    /// The user pressed Return here: a prompt or a command sent, as far as a
    /// key can say. Return or keypad Enter with no ⇧ ⌥ ⌃ ⌘ (⇧↩ is a new
    /// line in an agent's prompt), not a repeat, and not the Return that
    /// confirms an input method's composition. Pastes and a script's Return
    /// (`pressReturn(scripted:)`) don't come through here. Only that it
    /// happened is passed on, never what was typed: it is the sidebar's
    /// "recent activity" (`SectionSort`).
    var onSubmit: (() -> Void)?

    /// Whether `event` is a Return that `onSubmit` counts, given whether an
    /// input method was composing before or after it.
    static func isSubmit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                         composing: Bool) -> Bool {
        guard !isRepeat, !composing, keyCode == 0x24 || keyCode == 0x4C else { return false }
        return modifiers.intersection([.shift, .option, .control, .command]).isEmpty
    }

    /// Write `bytes` into this terminal as though the program had written
    /// them: by the road its output takes, so the record of its modes hears
    /// them, and a hibernated terminal keeps them for when it wakes. For the
    /// few things Wortel has to say to the terminal about a program it is
    /// ending (`TerminalModes.undo`). On the pty's queue, as every write into
    /// a terminal is.
    func writeAsOutput(_ bytes: [UInt8]) {
        // The keeper keeps this terminal: it writes them, so its terminal and
        // this copy of it stay one. The channel is frames, not output.
        if keptFeed != nil, let keeperSession {
            GhosttyRuntime.keeper?.inject(session: keeperSession, bytes)
            return
        }
        guard !bytes.isEmpty, let pty = ptyHost else { return }
        pty.enqueue { [weak pty] in
            bytes.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                pty?.onOutput?(base, raw.count)
            }
        }
    }

    /// Something went into the program's input: keys, a paste, a drop, or
    /// text a script sent. Not a click and not a scroll. What it is for is
    /// knowing that a prompt may be half written, or that the program was
    /// told something (`/new`) nobody else heard: an agent Wortel would end
    /// and bring back is left alone after this until it has worked again
    /// (`AgentSleep.Inputs.keysSinceWork`).
    var onTextInput: (() -> Void)?

    /// Every input path reports here, so the time and the hook can't drift apart.
    private func noteUserInput(text: Bool = true) {
        lastUserInputAt = Date()
        onUserInput?()
        if text { onTextInput?() }
    }

    private func noteInput(scripted: Bool) {
        guard scripted else { return noteUserInput() }
        lastScriptedInputAt = Date()
        onScriptedInput?()
        onTextInput?()
    }

    private(set) var pwd: String?
    private(set) var focused: Bool = false

    // IME / preedit state (see keyDown for the dance).
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]? = nil
    /// The first half of a character an input method sends in two
    /// (`insertText`, `SurrogatePairing`).
    private var surrogates = SurrogatePairing()
    private var lastPerformKeyEvent: TimeInterval?

    // Mouse state
    private var prevPressureStage: Int = 0
    /// Whether the left press now held down took the ⌘-as-Shift override;
    /// nil while no left button is down. See `pointerMods`.
    private var pressOverride: Bool?
    /// Where a left press with ⌘ held went down, to tell a ⌘-click from a
    /// ⌘-drag at the release. nil for any other press.
    private var commandPressPoint: NSPoint?
    /// A ⌘-click's rows, read at the release and kept until libghostty has
    /// said whether it found a link there (`openLink(_:tagged:)`) or, a turn
    /// of the main queue later, that it didn't (`mouseUp`).
    private var pendingLinkClick: TerminalLinkClick?
    private var cursor: NSCursor = .iBeam
    private var cursorVisible: Bool = true

    /// A tab is laid over this terminal in the main area (MainAreaController),
    /// which keeps it mounted and visible underneath. A covered terminal
    /// claims no cursor: its cursor rect would still apply under the cover,
    /// and WebKit shows no page cursor (a link's hand, Figma's grab) while the
    /// mouse is in anyone's cursor rect.
    var isCovered = false {
        didSet { if isCovered != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// Cell size in points, updated via GHOSTTY_ACTION_CELL_SIZE. Used for
    /// the IME candidate window position.
    private(set) var cellSize: NSSize = .init(width: 8, height: 16)

    /// Accessibility state (`SurfaceView+Accessibility`). Made before the
    /// surface, so the pty's output handler can hold it.
    let accessibilityWatch = SurfaceAccessibilityWatch()
    /// Reads the program's own status reports off its output, terminal or no
    /// terminal. See `ProgramStatusWatch`.
    let programStatusWatch = ProgramStatusWatch()

    /// Cached content size in points for backing-property changes (during
    /// animations the frame may lag the target size).
    private var contentSize: NSSize = .zero

    /// A session's own terminal, not one in its side column: the one whose
    /// size on screen is what a new one starts at (`firstSize`). A side
    /// terminal's page is the column's, a different size, and it is told
    /// nothing until it is shown.
    let isSessionTerminal: Bool

    /// The session a session's own terminal belongs to, for its size on
    /// screen (`shownSizes`). nil for a side terminal.
    private let shownSizeOwner: String?

    private static let firstSizeKey = "terminal.lastShownSize"
    private static let shownSizesKey = "terminal.shownSizes"

    /// The size, in points, each session's own terminal last had on screen,
    /// by session, kept across launches. What a terminal made or woken out of
    /// sight is told first, before `firstSize`, which is any session's.
    ///
    /// One size for every session was the size of whichever was shown last,
    /// and sessions differ: one has the side column open and another not.
    /// After a relaunch every session's terminal was told the last one's, so
    /// with the column open there, every agent out of sight was given 70
    /// columns in a window of 114. Claude Code answers a relaunch's repaint
    /// by printing its whole conversation again, at that width; shown later
    /// at its own width it redraws only what is on screen, so everything
    /// above was left wrapped at 70 for good (2026-11-19, the running app's
    /// log: every hidden terminal at 70x37 a minute after launch). Its own
    /// size is the one it will have when it is shown.
    private static var shownSizes: [String: NSSize] = {
        let stored = UserDefaults.standard.dictionary(forKey: shownSizesKey) as? [String: [Double]] ?? [:]
        return stored.compactMapValues { pair in
            pair.count == 2 && pair[0] >= 40 && pair[1] >= 20 ? NSSize(width: pair[0], height: pair[1]) : nil
        }
    }()

    /// Sizes of sessions that are no more, let go: called with every session
    /// there is, open or archived, once they are known at launch.
    static func keepShownSizes(only sessions: Set<UUID>) {
        let keep = Set(sessions.map(\.uuidString))
        let before = shownSizes.count
        shownSizes = shownSizes.filter { keep.contains($0.key) }
        if shownSizes.count != before { saveShownSizes() }
    }

    private static func saveShownSizes() {
        UserDefaults.standard.set(shownSizes.mapValues { [Double($0.width), Double($0.height)] },
                                  forKey: shownSizesKey)
    }

    /// The size, in points, a session's terminal last had on screen, kept
    /// across launches. A new terminal starts at it rather than at
    /// libghostty's placeholder of 45 columns by 15 rows, because most are
    /// made out of sight (every session's at launch, a hibernated one when it
    /// wakes, a new session made from the command line) and an agent in one
    /// works at whatever width it is given. Out of sight it changes only with
    /// the window (`followWindow`), so this first size is the one it works at
    /// until then or until it is shown.
    private static var firstSize: NSSize? = {
        guard let stored = UserDefaults.standard.array(forKey: firstSizeKey) as? [Double],
              stored.count == 2, stored[0] >= 40, stored[1] >= 20 else { return nil }
        return NSSize(width: stored[0], height: stored[1])
    }()

    /// Held in memory as it changes, which during a window drag is every
    /// frame, and written to defaults once it has settled for a second.
    private static func rememberShownSize(_ size: NSSize, for owner: String?) {
        let owned = owner.map { shownSizes[$0] != size } ?? false
        guard size != firstSize || owned else { return }
        firstSize = size
        if let owner { shownSizes[owner] = size }
        saveFirstSize?.cancel()
        let work = DispatchWorkItem {
            saveFirstSize = nil
            UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: firstSizeKey)
            saveShownSizes()
        }
        saveFirstSize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static var saveFirstSize: DispatchWorkItem?

    /// Whether a new surface on this view is about to be told a size of its
    /// own as it is set up (`tellFirstSize`), so that what is written into
    /// it can wait for that size (`waitForToldGrid`). Not a side terminal's,
    /// which is told nothing until it is shown.
    var expectsFirstSize: Bool {
        isSessionTerminal && (shownSizeOwner.flatMap { Self.shownSizes[$0] } ?? Self.firstSize) != nil
    }

    /// A new surface that nothing has told a size yet (made out of sight, or
    /// woken without ever having been shown) is told its session's last size
    /// on screen (`shownSizes`), or `firstSize` for a session never shown. One that has
    /// been on screen was told its own last size by
    /// `viewDidChangeBackingProperties` already. With neither, it is told
    /// nothing, and its pty keeps the size it has (`PtyHost.ignoreSizesUntilTold`).
    private func tellFirstSize() {
        // What a new surface is told as it is set up is not the first step
        // of a drag: the size its view gives it next, however soon, gets its
        // frame in the same commit (`frameForNewSize`).
        defer { sizedAt = nil }
        guard isSessionTerminal, surface != nil, toldSize == nil,
              let size = shownSizeOwner.flatMap({ Self.shownSizes[$0] }) ?? Self.firstSize else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        setSurfaceSize(width: UInt32(size.width * scale), height: UInt32(size.height * scale))
    }

    // MARK: Holding resizes while a pane animates

    /// How many pane animations are running. While any is, terminals keep the
    /// size they have and take the final one once, when the animation lands.
    ///
    /// Without this a pane sliding open resized every terminal beside it on
    /// every frame: ghostty re-wrapped the screen and the program inside got a
    /// resize signal each time, so an agent redrew its whole screen a dozen
    /// times in a quarter of a second. That work is most of what made the
    /// motion feel rough. During the hold the terminal's last frame is simply
    /// shown pinned to the top left, clipped or with a little page beside it.
    private static var resizeHolds = 0
    private static let resizeHoldReleased = Notification.Name("WortelSurfaceResizeHoldReleased")
    /// A size change arrived during a hold and still has to be applied.
    private var resizePending = false

    /// What the terminal was last told its size is, in pixels: the one fact
    /// that says whether it is the size of its view. nil for a surface that
    /// has not been told yet (a new one, after a wake or a restart).
    private var toldSize: (width: UInt32, height: UInt32)?

    /// When the terminal was last given a size, and since when the frame on
    /// its layer has been one of an older size (`frameForNewSize`).
    private var sizedAt: CFTimeInterval?
    private var staleSince: CFTimeInterval?
    private var frameCheck: DispatchWorkItem?

    /// When the hold count last left zero: the hold now in force began then,
    /// however many holds and releases have come and gone inside it. nil
    /// while nothing is held.
    private static var heldSince: Date?
    /// Longer than any pane animation (0.26 s) or wake (0.5 s) by a wide
    /// margin. A hold older than this is one whose release never came.
    private static let longestHold: TimeInterval = 2

    static func holdResizes() {
        resizeHolds += 1
        guard resizeHolds == 1 else { return }
        let began = Date()
        heldSince = began
        // A hold that is never released would freeze every terminal at the
        // size it has, for good: each change of size would wait for a release
        // that isn't coming. Nothing should hold this long, so one that does
        // is let go, and said. Asked of *this* stretch of holding, whatever
        // other holds and releases happen inside it: a count that went 1, 2,
        // 1 and stuck there is the leak this is for, and a check that any
        // later hold or release cancelled never caught it.
        DispatchQueue.main.asyncAfter(deadline: .now() + longestHold) {
            guard resizeHolds > 0, heldSince == began else { return }
            LayoutLog.log.fault("a resize hold was never released (\(resizeHolds) held): letting go")
            resizeHolds = 0
            heldSince = nil
            NotificationCenter.default.post(name: resizeHoldReleased, object: nil)
            settleSoon("a hold let go")
        }
    }

    /// Ask the terminals on screen to check their size against their view
    /// once the layout has had time to land. For the moments after which a
    /// size is most often stale: a launch, a session switch, a pane opening
    /// or closing. One check for however many of those come together.
    static func settleSoon(_ why: String) {
        settleWork?.cancel()
        let work = DispatchWorkItem {
            settleWork = nil
            NotificationCenter.default.post(name: reconcileRequested, object: why)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static var settleWork: DispatchWorkItem?

    private static let reconcileRequested = Notification.Name("WortelSurfaceReconcile")

    @objc private func reconcileWasRequested(_ notification: Notification) {
        reconcileSize(notification.object as? String ?? "asked")
    }

    /// Give the terminal its view's size if it has another one.
    ///
    /// **The safety net under every path above.** A size reaches the terminal
    /// when its view is resized, and is put off while a pane animates or the
    /// view is hidden, to be applied by the event that ends that. Each of
    /// those hand-offs is a place a size can be dropped, and a dropped one
    /// stays dropped until the window happens to be resized: the terminal
    /// drawn too wide and cut off by the column, or too narrow in a corner of
    /// its page (2026-11-18, both). So what was last *told* is compared with
    /// what the view *is*, at every moment things settle, whatever the flags
    /// say. One comparison when they agree.
    ///
    /// Each catch is logged with the state it was found in, because a catch
    /// is a hand-off that failed and should be found and fixed.
    func reconcileSize(_ why: String) {
        guard surface != nil, window != nil, !isHidden, Self.resizeHolds == 0 else { return }
        let size = frame.size
        guard size.width >= 40, size.height >= 20 else { return }
        let scaled = convertToBacking(size)
        let wanted = (width: UInt32(max(0, scaled.width)), height: UInt32(max(0, scaled.height)))
        if let told = toldSize, told == wanted { return }
        LayoutLog.log.notice("""
            terminal at the wrong size (\(why, privacy: .public)): told             \(self.toldSize.map { "\($0.width)x\($0.height)" } ?? "nothing", privacy: .public),             view \(wanted.width)x\(wanted.height) px, pending \(self.resizePending)
            """)
        resizePending = false
        sizeDidChange(size)
    }

    /// Shown again: take the size it missed while hidden, a moment later
    /// rather than now, in case the layout around it hasn't landed yet. A
    /// session switch doesn't rely on this: it lays the new session out first
    /// and shows the terminal inside a hold, whose release gives it its size
    /// (`MainSplitViewController.show`). This is for whatever else unhides a
    /// terminal (SwiftUI's own update, a side tab). Until then its last frame
    /// shows pinned top left, as during a hold.
    override var isHidden: Bool {
        didSet {
            guard oldValue, !isHidden else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, !self.isHidden, Self.resizeHolds == 0 else { return }
                if self.resizePending { self.sizeDidChange(self.frame.size) }
                self.reconcileSize("shown")
            }
        }
    }

    static func releaseResizes() {
        resizeHolds = max(0, resizeHolds - 1)
        guard resizeHolds == 0 else { return }
        heldSince = nil
        NotificationCenter.default.post(name: resizeHoldReleased, object: nil)
        // And once more when what the hold was for has landed: the last
        // frame of an animation can arrive after its completion.
        settleSoon("after a hold")
    }

    @objc private func resizeHoldDidRelease(_ notification: Notification) {
        if resizePending {
            resizePending = false
            sizeDidChange(frame.size)
        }
        // Whether or not a change was noted as waiting.
        reconcileSize("hold released")
    }

    /// The pty, when this surface's shell belongs to the keeper rather than to
    /// libghostty's exec backend. Held here because the view's lifetime is the
    /// session's, and nothing else outlives both the surface and the shell.
    var ptyHost: PtyHost?

    /// The keeper keeps this terminal: where its channel goes, surface or not
    /// (`KeptTerminalFeed`). nil for one the app keeps itself.
    var keptFeed: KeptTerminalFeed?
    /// Set while a terminal the keeper keeps has no surface: what to make the
    /// next one with. Nothing about the screen is kept here; the keeper has it.
    private var keptDrop: (fontSize: Float, dropped: DispatchTime, size: ghostty_surface_size_s, scale: CGFloat)?

    /// The keeper's id for this session, when its shell belongs to the keeper
    /// rather than to us. Closing the session has to tell the keeper so; the app
    /// merely *quitting* must not, which is the difference the whole feature
    /// turns on.
    var keeperSession: UUID?

    /// The keeper process that hosted this terminal's shell, as the keeper
    /// socket named it when the surface was created. Set only for a surface
    /// made from a keeper attachment; nil for one on the exec backend. Kept
    /// per terminal because the keeper can be replaced while the app runs, and
    /// a shell belongs to the one that forked it.
    var keeperPID: pid_t?

    /// The input this terminal was created with was not typed: its keeper
    /// would not hand the session over, and typing a resume into a shell of
    /// the app's own could start a second agent beside the first. The
    /// session goes on owing it.
    var initialInputDropped = false

    /// Set while this terminal's first line is still starting: the host keeps
    /// it under an empty page and what is typed is held (`StartCover`).
    private var startWatch: StartWatch?
    var isStarting: Bool { startWatch != nil }
    /// When the start now covered began, on `ProcessInfo.systemUptime`.
    var startBegan: TimeInterval? { startWatch?.began }

    /// Cover this terminal's start: called by the runtime for a session made
    /// with a line to run, once the keeper has typed it and before anything
    /// is read. What is typed from here on waits in `pty`; `feed` reads the
    /// output for how the start goes.
    func coverStart(pty: PtyHost, feed: KeptTerminalFeed, session: UUID) {
        pty.holdTyping()
        let agentIsKnown = { AgentResumeStore.currentMarkers()[session] != nil }
        let watch = StartWatch(session: session, agentIsKnown: agentIsKnown) { [weak self, weak pty, weak feed] end in
            pty?.releaseTyping(deliver: end.deliversTyping)
            if let feed { pty?.enqueue { feed.stopWatchingStart() } }
            guard let self else { return }
            self.startWatch = nil
            let waiting = self.startWaiters
            self.startWaiters = []
            waiting.forEach { $0(end) }
        }
        startWatch = watch
        feed.watchStart { [weak watch] events, time in
            DispatchQueue.main.async { watch?.heard(events, at: time) }
        }
    }

    /// The session's agent marker appeared: its line is an agent.
    func agentAppeared() { startWatch?.agentKnown() }

    /// The shell is gone, or the terminal is: a start still covered is over,
    /// and what is under the page (the reason the shell ended, say) is shown.
    func giveUpStart() { startWatch?.giveUp() }

    private var startWaiters: [(StartCover.End?) -> Void] = []

    /// Run `body` once this terminal's start is over: now, unless it is still
    /// covered. It is told how the start ended, nil when nothing was covered.
    /// For what is not a key: a paste is only wrapped as one once the
    /// program has asked for that, which it has not while it starts.
    func afterStart(_ body: @escaping (_ end: StartCover.End?) -> Void) {
        if isStarting { startWaiters.append(body) } else { body(nil) }
    }

    /// The keeper-hosted shell ended: everything on its tty is gone and the pty
    /// hung up. Called on the main thread, once per shell. When unset the
    /// terminal is simply told (`finishProcess`), which is what the exec
    /// backend does when its shell exits.
    var onShellEnded: (() -> Void)?

    /// Whether `finishProcess` has run for the current surface.
    private var processFinished = false

    /// When this view got the shell it has: made, or restarted after a lost
    /// keeper. A `wortel wait --idle` doesn't believe the quiet of a terminal
    /// younger than a few seconds, whose first line (`wortel new -- claude`)
    /// may not have started yet.
    private(set) var shellStartedAt = Date()

    /// The shell this terminal was running has ended: the keeper's pty hung
    /// up (`finishProcess`), or the exec backend saw its child exit. What
    /// `wortel wait --exit` waits for on a session that stays open after its
    /// shell, and true once there is no surface at all.
    var shellHasExited: Bool {
        // Hibernated is not gone: the shell is alive until the pty hangs up.
        guard let surface else { return keptDrop == nil || processFinished }
        return processFinished || ghostty_surface_process_exited(surface)
    }

    /// The pid of this session's shell, as reported by whoever spawned it.
    ///
    /// The root of everything the session is running: every dev server, build
    /// and agent in it is a descendant, so this is what turns "what is this
    /// session holding open" into a question the process table can answer (see
    /// `RunningJobs`). Distinct from `Session.runningShellPID`, which comes from
    /// the agent marker and therefore only exists while an agent is running.
    ///
    /// nil on the no-keeper fallback path, where libghostty spawns the shell
    /// itself and never tells us which pid it got.
    var shellPID: pid_t?

    // MARK: - Lifecycle

    /// Added to every shell this view starts, its first and any restart: the
    /// session's port block (`PortBlock.environment`).
    private let environment: [String: String]

    init(runtime: GhosttyRuntime, workingDirectory: String? = nil,
         sessionID: UUID? = nil, initialInput: String? = nil,
         environment: [String: String] = [:], fontSize: Float = 0,
         isSessionTerminal: Bool = false, coversStart: Bool = false) {
        self.runtime = runtime
        self.environment = environment
        self.isSessionTerminal = isSessionTerminal
        shownSizeOwner = isSessionTerminal ? sessionID?.uuidString : nil

        // Non-zero initial frame so the renderer's layer bounds are non-zero.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        accessibilityWatch.onChange = { [weak self] in self?.accessibilityScreenChanged() }
        // Before it has a window, and whether or not it ever gets one: this
        // is what has it told light or dark with the rest.
        runtime.register(self)
        programStatusWatch.onHeard = { [weak self] heard, replayed in
            switch heard {
            case .status(let report): self?.onProgramStatus?(report, replayed)
            case .notification(let said): self?.onNotification?(said.title, said.body, replayed)
            }
        }

        self.surface = runtime.newSurface(
            view: self,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            initialInput: initialInput,
            environment: environment,
            fontSize: fontSize,
            coversStart: coversStart)
        // The layer first: the size is what asks it for a frame.
        layerReplaced()
        tellFirstSize()

        NotificationCenter.default.addObserver(
            self, selector: #selector(resizeHoldDidRelease(_:)),
            name: Self.resizeHoldReleased, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reconcileWasRequested(_:)),
            name: Self.reconcileRequested, object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil)

        // Accept dropped files/images: we insert their paths at the prompt
        // (see performDragOperation) so agents can read them.
        registerForDraggedTypes([.fileURL, .png, .tiff])

        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        trackingAreas.forEach { removeTrackingArea($0) }
        if let surface {
            ghostty_surface_free(surface)
            // The view's going takes the layer with it: held as `retireLayer` does.
            if let layer { Self.holdRetiredLayer(layer) }
        }
    }

    /// True when the surface still has a process running that ghostty thinks
    /// warrants a confirmation before closing (per `confirm-close-surface`).
    /// False once the child has exited, or before the shell has spawned.
    var needsConfirmClose: Bool {
        guard let surface else { return keptDrop != nil && confirmCloseWhileHibernated }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Tell libghostty this terminal's process has exited, so it behaves as it
    /// does when an exec-backend shell exits: it says so on screen, stops
    /// asking for confirmation to close, and asks to close the surface unless
    /// configured to wait. Exit code 0, because the keeper reaped the shell
    /// and only the pty hanging up reached this side.
    ///
    /// The runtime is how long the shell had: from `shellStartedAt` to
    /// `endedAt`, when its pty hung up (the caller may tell libghostty later).
    /// It was 0, and libghostty takes any exit within its
    /// `abnormal-command-exit-runtime` (250 ms) as a launch that failed, and
    /// on macOS ignores the exit code: it printed a red "failed to launch"
    /// banner and didn't ask to close, so `exit` left the session open until
    /// the next key. A shell that really does die at once (a broken
    /// `.zshrc`) still gets the banner and keeps its session, as with the
    /// exec backend, rather than the session closing with no word.
    ///
    /// Once per surface, and nothing at all once the surface is gone.
    func finishProcess(endedAt: Date = Date()) {
        guard !processFinished else { return }
        processEndedAt = endedAt
        guard let surface else {
            // Hibernated: the terminal is told when it wakes (`wake`).
            if keptDrop != nil { processFinished = true }
            return
        }
        processFinished = true
        ghostty_surface_process_exit(surface, 0, processRan)
    }

    /// When the shell ended, kept for a terminal that was asleep then and is
    /// told when it wakes: told 0 ms, libghostty takes any end for a failed
    /// launch, shows its red banner and keeps the session open.
    private var processEndedAt: Date?

    /// How long the shell ran, in milliseconds, as `ghostty_surface_process_exit`
    /// takes it.
    private var processRan: UInt64 {
        UInt64(max((processEndedAt ?? Date()).timeIntervalSince(shellStartedAt), 0) * 1000)
    }

    /// Explicit teardown (deinit ordering with AppKit view hierarchies is
    /// unreliable; call this when the session closes).
    func close() {
        // Closing a *session* is the user saying they are done with it, so the
        // shell goes too — unlike quitting the app, which deliberately leaves it
        // running and is handled by the connection simply dropping.
        // Closed while its start was still covered: what was typed under
        // the page is for nobody now.
        startWatch?.giveUp()
        if let keeperSession {
            GhosttyRuntime.keeper?.close(session: keeperSession)
            // Its terminal's modes went with it.
            TerminalModeRecorder.shared.forget(session: keeperSession)
            ptyHost?.release() // the keeper owns the process; just let go
        } else {
            ptyHost?.stop()
        }
        keeperSession = nil
        // Whoever waits on a restore under way is told now: the terminal is
        // gone, which `wortel read` answers as a session that has closed.
        if isRestoring {
            isRestoring = false
            let waiting = restoreWaiters
            restoreWaiters = []
            waiting.forEach { $0() }
        }
        let pty = ptyHost
        ptyHost = nil
        // Nothing more goes into the surface from the channel, from the next
        // read on (none come after the release above).
        if let feed = keptFeed { pty?.enqueue { feed.hide() } }
        keptFeed = nil
        keptDrop = nil
        guard let surface else { return }
        self.surface = nil
        // Off the view now, held past the free: see `retireLayer`. Taken here
        // rather than at the free, so a restart in between can't replace it
        // first and drop it unheld.
        let oldLayer = detachLayer()
        // The pty's queue writes into this surface — the replay right after
        // it was created, then every read — so it is freed only once that
        // queue has nothing left to write. See `PtyHost.enqueue`.
        // `self` is held until then: the surface's userdata points at it. So
        // is `pty`: the surface's `receive_userdata` is an unretained pointer
        // to it, and libghostty's IO thread may still write an answer through
        // that pointer until the surface is gone.
        guard let pty else {
            ghostty_surface_free(surface)
            if let oldLayer { Self.holdRetiredLayer(oldLayer) }
            return
        }
        pty.enqueue {
            DispatchQueue.main.async {
                withExtendedLifetime((self, pty)) { ghostty_surface_free(surface) }
                if let oldLayer { Self.holdRetiredLayer(oldLayer) }
            }
        }
    }

    /// Take libghostty's layer off this view once its surface is freed, and
    /// keep it alive a little longer. Both halves were a crash.
    ///
    /// The layer outlives its surface: libghostty releases its own reference
    /// on free but leaves the layer on the view, still pointing at the freed
    /// renderer, and its `display` draws a frame through that pointer. In
    /// Ghostty.app the view goes with the surface, so nothing ever asks. Here
    /// a hibernated terminal keeps its view, hidden in the window, and a
    /// resize of it (the sidebar opening or closing resizes every hidden
    /// terminal) or a change of scale asked its layer to display: EXC_BAD_ACCESS
    /// in `renderer.generic.Renderer.drawFrame` under a Core Animation commit
    /// (2026-11-17). So the view gets a plain layer instead.
    ///
    /// Not dropped at once: a frame the renderer finished just before the free
    /// hands its IOSurface to the layer in a block on the main queue
    /// (`Frame.bufferCompleted`), which holds the layer unretained.
    private func retireLayer() {
        if let old = detachLayer() { Self.holdRetiredLayer(old) }
    }

    /// Put a plain layer on the view in place of libghostty's, and hand back
    /// libghostty's for the caller to hold until its surface is freed.
    private func detachLayer() -> CALayer? {
        guard let old = layer else { return nil }
        let blank = CALayer()
        blank.contentsScale = old.contentsScale
        layer = blank
        return old
    }

    /// A new surface has just put its own layer on the view: pinned, as the
    /// last one was, if a size is still waiting for it (`setFrameSize`).
    private func layerReplaced() {
        if resizePending { layer?.contentsGravity = .topLeft }
        sizedAt = nil
        staleSince = nil
        // libghostty's layer draws a frame on the main thread every time its
        // bounds change. We ask for that frame ourselves, when it is worth
        // stopping for: see `frameForNewSize`.
        layer?.needsDisplayOnBoundsChange = Self.frameOnEveryResize
        // A frame of an older size is shown at its own size, pinned to the
        // top left, until the next one arrives. Never over what is beside it.
        layer?.masksToBounds = true
    }

    /// The pixel size of the frame the layer is showing, if it has one.
    private var shownFrameSize: (width: UInt32, height: UInt32)? {
        guard let contents = layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let frame = contents as! IOSurfaceRef
        return (UInt32(IOSurfaceGetWidth(frame)), UInt32(IOSurfaceGetHeight(frame)))
    }

    /// How long ago the last size must be for this one to count as part of
    /// the same drag, and how long a frame of an older size may stay up.
    private static let dragGap: CFTimeInterval = 0.05
    private static let longestStale: CFTimeInterval = 0.03

    /// Whether the terminal's new size gets a frame now, on the main thread,
    /// or the one the renderer draws on its own thread a moment later.
    ///
    /// A frame now is what libghostty does for every change of size. It puts
    /// the frame in the same commit as the new size, so nothing is seen in
    /// between, and it stops the main thread until the GPU has finished it.
    /// For one change of size that is the right trade: a session switch, a
    /// pane landing. Under a drag it is paid at every step. Measured over
    /// 480 steps of a window resize at 120 Hz (`scripts/bench-resize.sh`,
    /// 2026-11-19, the window on screen), a step cost 6.8 ms with it and 4.5
    /// without, and one step in eight took longer than the 8.3 ms a frame
    /// lasts, against one in eighty: the edge stood still.
    ///
    /// The frame it buys is rarely a new picture. The terminal re-wraps on
    /// its own thread after the size is told, so the frame drawn in the same
    /// commit mostly shows the screen as it was, which the layer does without
    /// being asked: it pins the frame it has to the top left at its own size
    /// (the padding does not move, `window-padding-balance` is off, and the
    /// strip a smaller frame leaves uncovered shows the page behind the
    /// terminal, which is the colour the terminal draws its own background
    /// in: `Chrome.content`, kept equal by `PageColourTests`).
    ///
    /// So a size that follows another within `dragGap` skips the frame, and
    /// the renderer's own one shows the new screen a frame later. One thing
    /// can go wrong with that: libghostty throws the renderer's frame away
    /// if the layer has another size by the time it arrives, and a drag that
    /// stays in step with the renderer loses them all. So a frame of an
    /// older size stays up for `longestStale` at most, and then this size
    /// gets its frame now; and one is asked for when the drag ends on a
    /// frame that never came (`checkFrameAfterDrag`).
    private func frameForNewSize(sizeBefore: (width: UInt32, height: UInt32)?) {
        guard !Self.frameOnEveryResize else { return }
        let now = CACurrentMediaTime()
        let inDrag = sizedAt.map { now - $0 < Self.dragGap } ?? false
        sizedAt = now
        guard inDrag, let sizeBefore, let shown = shownFrameSize else {
            staleSince = nil
            layer?.setNeedsDisplay()
            return
        }
        checkFrameAfterDrag()
        guard shown != sizeBefore else {
            staleSince = nil
            return
        }
        guard let since = staleSince else {
            staleSince = now
            return
        }
        if now - since >= Self.longestStale {
            staleSince = nil
            layer?.setNeedsDisplay()
        }
    }

    /// The drag's last size, a moment after it: if its frame never came, it
    /// gets one now. One check for however many steps the drag had.
    private func checkFrameAfterDrag() {
        frameCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.surface != nil, let told = self.toldSize else { return }
            self.frameCheck = nil
            self.staleSince = nil
            if let shown = self.shownFrameSize, shown == told { return }
            self.layer?.setNeedsDisplay()
        }
        frameCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragGap * 2, execute: check)
    }

    #if DEBUG
    /// What the terminal has been told against what it is, for `SwitchProbe`.
    struct DebugState {
        var told: (UInt32, UInt32)?
        var columns: UInt16 = 0
        var rows: UInt16 = 0
        /// The width its columns take, without padding.
        var gridWidthPx = 0
        var shown: (UInt32, UInt32)?
        var layerPx = (0, 0)
        var pending = false
        var holds = 0
        var hidden = false
    }

    var debugState: DebugState {
        var state = DebugState(told: toldSize.map { ($0.width, $0.height) }, shown: shownFrameSize.map { ($0.width, $0.height) },
                               pending: resizePending, holds: Self.resizeHolds, hidden: isHidden)
        if let surface {
            let size = ghostty_surface_size(surface)
            state.columns = size.columns
            state.rows = size.rows
            state.gridWidthPx = Int(size.columns) * Int(size.cell_width_px)
        }
        if let layer {
            state.layerPx = (Int(layer.bounds.width * layer.contentsScale), Int(layer.bounds.height * layer.contentsScale))
        }
        return state
    }
    #endif

    /// A frame on every change of size, as libghostty has it. Never set by
    /// the app: `ResizeBench` flips it to measure the two against each other.
    nonisolated(unsafe) static var frameOnEveryResize = false {
        didSet {
            for window in NSApp.windows {
                func visit(_ view: NSView) {
                    if let terminal = view as? SurfaceView, terminal.surface != nil { terminal.layerReplaced() }
                    view.subviews.forEach(visit)
                }
                window.contentView.map(visit)
            }
        }
    }

    private static func holdRetiredLayer(_ layer: CALayer) {
        nonisolated(unsafe) let layer = layer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withExtendedLifetime(layer) {} }
    }

    /// Start a new shell in this view, in place of one that went with its
    /// keeper.
    ///
    /// The view stays where it is (in its host, its tab, first responder or
    /// not) and only what is behind it is replaced, which is why this is not a
    /// new `SurfaceView`: every host keeps its views for the life of the
    /// session and would need telling. The old terminal's screen goes with the
    /// old surface; there is nothing left behind it to talk to.
    ///
    /// Nobody is told the old session closed. Its keeper is gone, and a
    /// `close` sent to the new one, under the same id, would end the shell
    /// this is about to get.
    ///
    /// `isNewShell: false` is the same session attached to again (its channel
    /// was let go while it runs, `GhosttyRuntime.keeperTerminalSurface`): the
    /// keeper forks nothing, and what the program set stays on record.
    func restartShell(workingDirectory: String?, sessionID: UUID, initialInput: String?,
                      isNewShell: Bool = true) {
        guard let runtime else { return }
        // A start still covered is over: this is another shell, or another
        // channel to the same one, and the watch was reading the old.
        startWatch?.giveUp()
        if let feed = keptFeed, let old = ptyHost { old.enqueue { feed.hide() } }
        keptFeed = nil
        keptDrop = nil
        let pty = ptyHost
        pty?.release() // let go of, not hung up: no `onShellEnded` for it
        ptyHost = nil
        keeperSession = nil
        keeperPID = nil
        initialInputDropped = false
        shellPID = nil
        processFinished = false
        shellStartedAt = Date()
        // Whatever the old program told its terminal is not true of a new
        // shell.
        if isNewShell { TerminalModeRecorder.shared.forget(session: sessionID) }
        if let old = surface {
            surface = nil
            // Off the view at once and held past the old surface's free, as
            // `retireLayer` explains. The new surface puts its own on; if
            // there is none, the view is left with a plain one.
            let oldLayer = detachLayer()
            // Freed only once the old pty's queue has nothing left to write
            // into it, as in `close`.
            if let pty {
                // `pty` is kept until the old surface is freed, as in `close`.
                pty.enqueue {
                    DispatchQueue.main.async {
                        withExtendedLifetime(pty) { ghostty_surface_free(old) }
                        if let oldLayer { Self.holdRetiredLayer(oldLayer) }
                    }
                }
            } else {
                ghostty_surface_free(old)
                if let oldLayer { Self.holdRetiredLayer(oldLayer) }
            }
        }

        surface = runtime.newSurface(view: self, workingDirectory: workingDirectory,
                                     sessionID: sessionID, initialInput: initialInput,
                                     environment: environment)
        toldSize = nil
        guard let surface else { return }
        layerReplaced()
        // What `viewDidMoveToWindow` and the host told the old surface, told
        // again: the screen, the scale and last real size, the appearance,
        // whether it is shown, and whether it has the keyboard.
        if let window { ghostty_surface_set_display_id(surface, window.screen?.displayID ?? 0) }
        viewDidChangeBackingProperties()
        tellFirstSize()
        runtime.syncColorScheme(because: "a shell was restarted")
        ghostty_surface_set_occlusion(surface, !isHidden)
        focused = false
        updateFocus()
    }

    // MARK: - Out of sight

    /// A session's terminal out of sight gives back its surface: the
    /// renderer's frames, the scrollback, the font atlas, about 70 MB
    /// (measured 2026-11-17). Nothing is saved and nothing can be lost: the
    /// keeper keeps the session's terminal, and a surface shown again is
    /// restored from a snapshot of it (`KeeperCommand.resync`). The channel
    /// goes on being read meanwhile (`KeptTerminalFeed`), for the program's
    /// status and for what the surface would have raised (`raise`).
    var isHibernated: Bool { keptDrop != nil }

    /// The keeper keeps this terminal, so its surface can go. nil feed: the
    /// exec backend, where the terminal *is* the shell's parent.
    var keepsTerminalInKeeper: Bool { keptFeed != nil }

    /// `needsConfirmClose` for a terminal that isn't there to ask: what it
    /// said when it went, until the shell is seen back at its prompt.
    private var confirmCloseWhileHibernated = false

    /// Give back the surface, keeping everything else. Only out of sight.
    func hibernate() {
        dropKeptSurface()
    }

    /// Bring the surface back, restored from the keeper's terminal. Called
    /// before the view is shown. `onRestored` runs on the main thread once
    /// the screen is back, at once if it never went.
    func wake(onRestored: (() -> Void)? = nil) {
        guard keptDrop != nil else { return afterRestore(onRestored) }
        wakeKeptSurface(onRestored: onRestored)
    }

    /// Free the surface of a terminal the keeper keeps. Its channel goes on
    /// being read for the program's status; its screen is the keeper's, and
    /// comes back exactly when it is shown (`wakeKeptSurface`).
    private func dropKeptSurface() {
        // Not one still being restored: what waits on its restore (`wortel
        // read`, `wait`) would wait for a surface that is gone.
        guard let old = surface, let pty = ptyHost, let feed = keptFeed, keptDrop == nil, !isRestoring,
              !processFinished, isHidden || superview == nil else { return }
        let fontSize = ghostty_surface_inherited_config(old, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
        confirmCloseWhileHibernated = ghostty_surface_needs_confirm_quit(old)
        keptDrop = (fontSize, .now(), ghostty_surface_size(old),
                    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        surface = nil
        focused = false
        retireLayer()
        // Out of the feed first, on the queue that writes into it; freed
        // after, on main, once nothing can be writing into it.
        // `self` and `pty` are held until the free: the surface's userdata
        // points at the view, its `receive_userdata` at the pty, both
        // unretained, as in `close`.
        pty.enqueue {
            feed.hide()
            DispatchQueue.main.async { withExtendedLifetime((self, pty)) { ghostty_surface_free(old) } }
        }
        HibernationLog.log.notice("dropped the terminal of \(self.keeperSession?.uuidString ?? "?", privacy: .public); the keeper keeps it")
    }

    /// A new surface for a terminal the keeper keeps, restored from a
    /// snapshot the keeper sends down its channel. `onRestored` runs on main
    /// once it is.
    private func wakeKeptSurface(onRestored: (() -> Void)?) {
        guard let drop = keptDrop, let runtime, let pty = ptyHost, let feed = keptFeed,
              let session = keeperSession else { return afterRestore(onRestored) }
        let started = DispatchTime.now()
        guard let new = runtime.keptSurface(view: self, pty: pty, fontSize: drop.fontSize) else {
            HibernationLog.log.error("could not wake \(session.uuidString, privacy: .public)")
            onRestored?()
            return
        }
        keptDrop = nil
        confirmCloseWhileHibernated = false
        isRestoring = true
        surface = new
        toldSize = nil
        layerReplaced()
        if let window { ghostty_surface_set_display_id(new, window.screen?.displayID ?? 0) }
        viewDidChangeBackingProperties()
        tellFirstSize()
        runtime.syncColorScheme(because: "a terminal woke")
        ghostty_surface_set_occlusion(new, !isHidden)
        updateFocus()

        let waitsForSize = expectsFirstSize
        pty.enqueue { [weak self] in
            feed.show(in: new, waitsForSize: waitsForSize) { restored in
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                HibernationLog.log.notice("""
                    woke \(session.uuidString, privacy: .public) from the keeper's terminal \
                    in \(ms, format: .fixed(precision: 1)) ms\(restored ? "" : ", but its snapshot would not restore", privacy: .public)
                    """)
                DispatchQueue.main.async {
                    guard let self else { onRestored?(); return }
                    if self.processFinished, self.surface == new { ghostty_surface_process_exit(new, 0, self.processRan) }
                    if self.surface == new { self.isRestoring = false }
                    onRestored?()
                    let waiting = self.restoreWaiters
                    self.restoreWaiters = []
                    waiting.forEach { $0() }
                    self.reconcileSize("woken")
                }
            }
        }
        // After the feed is waiting for it: the snapshot comes down the same
        // channel, read on the same queue, so it cannot arrive first. A
        // session whose shell has ended is no longer the keeper's to snapshot:
        // its last snapshot came down the channel as it ended, and the feed
        // shows that (`KeptTerminalFeed.show`).
        if !processFinished { GhosttyRuntime.keeper?.resync(session: session) }
        // And if no snapshot comes (the keeper went, or would not say), this
        // terminal is not left restoring for good: what waits on it goes on.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restorePatience) { [weak self] in
            guard let self, self.surface == new, self.isRestoring else { return }
            HibernationLog.log.error("no snapshot came for \(session.uuidString, privacy: .public); shown as it is")
            if self.processFinished { ghostty_surface_process_exit(new, 0, self.processRan) }
            self.isRestoring = false
            let waiting = self.restoreWaiters
            self.restoreWaiters = []
            waiting.forEach { $0() }
        }
    }

    /// The longest a woken terminal waits for its snapshot.
    private static let restorePatience: TimeInterval = 3

    /// The grid a terminal has, asked of the terminal: where its cursor ends
    /// up when sent to the far corner, counted in cells by sending it one
    /// cell from home first. `ghostty_surface_size` is no answer to this: it
    /// is worked out from the size the surface was last *told*, at once,
    /// while the terminal takes that size on libghostty's IO thread some 25 ms
    /// later (it gathers resizes for that long). On a terminal nothing has
    /// been written into, which it leaves as it found it, cursor at home.
    static func actualGrid(of surface: ghostty_surface_t) -> (columns: Int, rows: Int)? {
        func cursor(after sequence: String) -> (x: Double, y: Double) {
            Array(sequence.utf8).withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_write_buffer(surface, base, UInt(raw.count))
            }
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            return (x, y)
        }
        let home = cursor(after: "\u{1B}[1;1H")
        let step = cursor(after: "\u{1B}[2;2H")
        let far = cursor(after: "\u{1B}[999;999H")
        _ = cursor(after: "\u{1B}[1;1H")
        let cell = (width: step.x - home.x, height: step.y - home.y)
        guard cell.width > 0, cell.height > 0 else { return nil }
        return (Int(((far.x - home.x) / cell.width).rounded()) + 1,
                Int(((far.y - home.y) / cell.height).rounded()) + 1)
    }

    /// Hold the pty's queue until a new terminal has been told a size and has
    /// taken it, for a terminal whose size is told on the main thread after
    /// it is made (`tellFirstSize`), so after whatever was queued for it.
    /// `ghostty_surface_size` says what it was told; until then it is
    /// libghostty's placeholder. See `waitForGrid` for why it matters.
    static func waitForToldGrid(_ surface: ghostty_surface_t, patience: TimeInterval = 0.25)
        -> (ms: Double, reached: Bool) {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            let told = ghostty_surface_size(surface)
            let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            let placeholder = told.columns == 45 && told.rows == 15
            if !placeholder, told.columns > 1, told.rows > 1 {
                let rest = max(0, patience - waited / 1000)
                let wait = waitForGrid(surface, columns: Int(told.columns), rows: Int(told.rows), patience: rest)
                return (waited + wait.ms, wait.reached)
            }
            if waited > patience * 1000 { return (waited, false) }
            usleep(1000)
        }
    }

    /// Hold the pty's queue until a new terminal has the grid it was told.
    ///
    /// A new surface is 45 columns by 15 rows, libghostty's own, whatever it
    /// is told the moment it exists: the size is taken a little later, on
    /// another thread. A wake wrote the saved screen and what had been missed
    /// into it about 6 ms after making it, so into those 45 columns. A saved
    /// screen survives that, because its lines are re-wrapped when the real
    /// size lands. What the program wrote meanwhile does not: an agent draws
    /// in place, each piece from where the last ended, and at 45 columns a
    /// line of 78 is two rows, so "up three and clear" clears a line and a
    /// half. Found with a script of 2026-11-19, since gone with what it tested: an
    /// agent woken as it began to write had 3 lines of 120 missing and 18
    /// left over, with nothing lost, and its status line cut at exactly
    /// column 45. It is also what a session looked like when it was shown
    /// mid-turn after a hibernation.
    ///
    /// Asked every millisecond, for a quarter of a second at the most: the
    /// size lands after about 25 ms. Only this session's queue waits.
    static func waitForGrid(
        _ surface: ghostty_surface_t, columns: Int, rows: Int, patience: TimeInterval = 0.25
    ) -> (ms: Double, reached: Bool, grid: (columns: Int, rows: Int)?) {
        let started = DispatchTime.now().uptimeNanoseconds
        var grid = actualGrid(of: surface)
        while true {
            let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            if let grid, grid.columns == columns, grid.rows == rows { return (waited, true, grid) }
            if waited > patience * 1000 { return (waited, false, grid) }
            usleep(1000)
            grid = actualGrid(of: surface)
        }
    }

    /// Woken, and the screen not yet back. Reading it now reads the old one.
    private(set) var isRestoring = false

    /// Whoever asked to be told when the restore now under way is done.
    private var restoreWaiters: [() -> Void] = []

    /// Run `block` once this terminal is whole: now, unless a wake is still
    /// waiting for its snapshot.
    func afterRestore(_ block: (() -> Void)?) {
        guard let block else { return }
        if isRestoring { restoreWaiters.append(block) } else { block() }
    }

    /// What the terminal would have told the app, told by the scanner instead:
    /// the same callbacks, so nothing downstream knows the difference.
    func raise(_ signals: [SignalScanner.Signal]) {
        for signal in signals {
            switch signal {
            case .title(let title): onTitleChange?(title)
            case .pwd(let pwd): reportPwd(pwd)
            case .bell: onBell?()
            case .progress(let active, let errored): onProgress?(active, errored)
            case .commandFinished(let exitCode, let durationNs):
                confirmCloseWhileHibernated = false
                onCommandFinished?(exitCode, durationNs)
            // Heard by the terminal's own listener, hibernated or not
            // (`ProgramStatusWatch`): raised here as well it would be twice.
            case .notification: break
            }
        }
    }

    // MARK: - Focus & visibility

    override var acceptsFirstResponder: Bool { true }

    /// The window is movable-by-background (so you can drag it by the sidebar),
    /// but the terminal must keep click-drags for text selection instead of
    /// moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            updateFocus(firstResponder: true)
            Self.onKeyboardActivity?(self)
        }
        return result
    }

    /// A terminal took the keyboard or was typed in. The app uses it to know
    /// which area you're working in (GitPanelModel.lastRegion). Called on every
    /// key, so what it does has to be cheap: it is a pointer comparison and a
    /// lookup in a handful of tabs.
    static var onKeyboardActivity: ((SurfaceView) -> Void)?

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { updateFocus(firstResponder: false) }
        return result
    }

    /// Effective focus = first responder AND key window. Both states feed
    /// libghostty, which forwards focus-in/out (DECSET 1004) to the child —
    /// agents like Codex only emit their "needs you" notification while the
    /// terminal reports unfocused, so app/window deactivation must reach them.
    private func updateFocus(firstResponder: Bool? = nil) {
        let isFirstResponder = firstResponder ?? (window?.firstResponder === self)
        focusDidChange(isFirstResponder && (window?.isKeyWindow ?? false))
    }

    // MARK: Following the window while out of sight

    /// The window's content size when this terminal was last told a size,
    /// for one that is out of sight to follow the window by the same amount
    /// (`followWindow`).
    private var windowSizeWhenTold: NSSize?
    private var followWork: DispatchWorkItem?

    @objc private func windowDidResize(_ notification: Notification) {
        guard isHidden, surface != nil || keptDrop != nil else { return }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.followWork = nil
            self?.followWindow()
        }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// A session's terminal out of sight takes the window's change of size,
    /// once the window has stopped changing: the size it will have when it
    /// is shown, since the panes beside it keep theirs and the terminal is
    /// what gives (`MainSplitViewController`). Left at the old size, what its
    /// agent prints meanwhile is laid out for a width it will never be shown
    /// at, and stays so in the scrollback; that was the rule ("never resized
    /// while hidden", 2026-09-29) for the storm of resizes a session switch
    /// made when every hidden terminal took the shown one's size. This is
    /// once a window resize, and to a terminal's own size.
    private func followWindow() {
        guard isSessionTerminal, isHidden, surface != nil || keptDrop != nil, let told = toldSize,
              let then = windowSizeWhenTold, let now = window?.contentLayoutRect.size else { return }
        guard Self.resizeHolds == 0 else {
            // A pane is moving: after it lands.
            followWork = DispatchWorkItem { [weak self] in self?.followWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: followWork!)
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let dw = (now.width - then.width) * scale, dh = (now.height - then.height) * scale
        guard abs(dw) >= 1 || abs(dh) >= 1 else { return }
        let width = max(40 * scale, CGFloat(told.width) + dw)
        let height = max(20 * scale, CGFloat(told.height) + dh)
        guard surface != nil else { return followWindowWithoutSurface(width: UInt32(width), height: UInt32(height)) }
        setSurfaceSize(width: UInt32(width), height: UInt32(height))
        // What a change of scale or screen passes on again
        // (`viewDidChangeBackingProperties`): this size, not the one before.
        contentSize = NSSize(width: width / scale, height: height / scale)
        LayoutLog.log.debug("followed the window out of sight: \(told.width)x\(told.height) to \(UInt32(width))x\(UInt32(height)) px")
    }

    /// `followWindow` for a terminal the keeper keeps whose surface was
    /// dropped: the grid libghostty would make of the new size goes to the
    /// keeper, which resizes the pty and its terminal, so the program works
    /// at the width it will be shown at. The surface made when it is shown
    /// gets the same grid, and nothing is resized then.
    private func followWindowWithoutSurface(width: UInt32, height: UInt32) {
        guard let drop = keptDrop, let session = keeperSession,
              let grid = Self.grid(width: width, height: height, cell: drop.size, scale: drop.scale)
        else { return }
        toldSize = (width, height)
        windowSizeWhenTold = window?.contentLayoutRect.size
        guard grid.columns != drop.size.columns || grid.rows != drop.size.rows else { return }
        var size = drop.size
        size.columns = grid.columns
        size.rows = grid.rows
        size.width_px = width
        size.height_px = height
        keptDrop?.size = size
        GhosttyRuntime.keeper?.resize(session: session, columns: grid.columns, rows: grid.rows,
                                      cellWidth: drop.size.cell_width_px, cellHeight: drop.size.cell_height_px)
        LayoutLog.log.debug("followed the window with no terminal: \(grid.columns)x\(grid.rows), told the keeper")
    }

    /// The grid libghostty makes of a surface `width` by `height` pixels:
    /// what is left after the padding (`window-padding-x`, `-y` in
    /// `wortel.conf`, in points on each side), in whole cells. nil when the
    /// same sum does not give back the grid the surface had, which means it
    /// is not libghostty's sum any more and must not be guessed at.
    static func grid(width: UInt32, height: UInt32, cell: ghostty_surface_size_s, scale: CGFloat)
        -> (columns: UInt16, rows: UInt16)? {
        guard cell.cell_width_px > 0, cell.cell_height_px > 0 else { return nil }
        func fit(_ pixels: UInt32, padding: CGFloat, cellSize: UInt32) -> UInt16 {
            let free = max(0, Int(pixels) - Int((2 * padding * scale).rounded(.down)))
            return UInt16(clamping: max(1, free / Int(cellSize)))
        }
        let check = (fit(cell.width_px, padding: Self.padding.x, cellSize: cell.cell_width_px),
                     fit(cell.height_px, padding: Self.padding.y, cellSize: cell.cell_height_px))
        guard check.0 == cell.columns, check.1 == cell.rows else {
            LayoutLog.log.error("""
                the grid sum gives \(check.0)x\(check.1) for a surface of \(cell.columns)x\(cell.rows); \
                not following the window without it
                """)
            return nil
        }
        return (fit(width, padding: Self.padding.x, cellSize: cell.cell_width_px),
                fit(height, padding: Self.padding.y, cellSize: cell.cell_height_px))
    }

    /// `window-padding-x` and `-y` from the bundled config, in points.
    private static let padding: (x: CGFloat, y: CGFloat) = {
        let conf = Bundle.main.resourceURL.flatMap { TerminalTheme.settings(at: $0.appendingPathComponent("wortel.conf")) }
        let x = conf?["window-padding-x"]?.last.flatMap(Double.init) ?? 2
        let y = conf?["window-padding-y"]?.last.flatMap(Double.init) ?? 2
        return (CGFloat(x), CGFloat(y))
    }()

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        updateFocus()
    }

    func focusDidChange(_ focused: Bool) {
        guard let surface else { return }
        guard self.focused != focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    /// True = the surface is visible and should render.
    func occlusionDidChange(visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: - Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { accessibilityChangeMissedWhileAway() }
        // Track key-window state so effective focus (and thus the child's
        // DECSET 1004 focus reporting) drops when the app deactivates.
        // Selector-based observers auto-unregister on dealloc.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                               name: NSWindow.didResignKeyNotification, object: window)
            if isSessionTerminal {
                center.addObserver(self, selector: #selector(windowDidResize(_:)),
                                   name: NSWindow.didResizeNotification, object: window)
            }
        }
        guard let window, let surface else { return }
        ghostty_surface_set_display_id(surface, window.screen?.displayID ?? 0)
        viewDidChangeBackingProperties()
        sizeDidChange(frame.size)
        runtime?.syncColorScheme(because: "a terminal joined the window")
        // The frame it arrives with is often not the one it ends up with
        // (during launch the host is still zero-sized), and a size too small
        // to be real is not passed on at all.
        DispatchQueue.main.async { [weak self] in self?.reconcileSize("joined the window") }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: NSSize) {
        guard window != nil else { return }
        // A pane collapsing (the side column hiding, the terminal behind full
        // view) sizes its terminal down to nothing on the way out. Passed on,
        // that reflows the program to a single column and back again when the
        // pane returns: an agent redraws its whole screen twice for a view
        // that was only put away. Nothing this small is a size anyone works
        // at, so it keeps the last real one.
        guard size.width >= 40, size.height >= 20 else { return }
        // Hidden (another session's terminal, a side terminal behind another
        // tab) takes no size either, for the same reason as a hold. Every
        // session's terminal sits in one container, so switching between two
        // sessions whose columns differ resized all of them: each hidden one
        // re-wrapped and its program got a SIGWINCH, so every agent in the
        // sidebar redrew its whole screen, for a width that wasn't even its
        // own (it gets resized back when you return to it). It takes whatever
        // size is current when it's shown again (`isHidden` below). A
        // session's own terminal out of sight does follow the window, by the
        // window's change, once a resize ends (`followWindow`).
        if Self.resizeHolds > 0 || isHidden {
            if !resizePending {
                resizePending = true
                // Pinned, not stretched, while it waits for its real size;
                // left that way after, since a layer drawn at its own size
                // never needs stretching.
                layer?.contentsGravity = .topLeft
            }
            return
        }
        resizePending = false
        let reflowed = size != contentSize
        contentSize = size
        if reflowed {
            onSizeChange?()
            accessibilityWatch.outputArrived()
            if isSessionTerminal, window != nil { Self.rememberShownSize(size, for: shownSizeOwner) }
        }
        let scaled = convertToBacking(size)
        setSurfaceSize(width: UInt32(max(0, scaled.width)), height: UInt32(max(0, scaled.height)))
    }

    private func setSurfaceSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        // Before the size, so the grid it makes of it reaches the program.
        ptyHost?.sizeWasTold()
        let before = toldSize
        ghostty_surface_set_size(surface, width, height)
        toldSize = (width, height)
        windowSizeWhenTold = window?.contentLayoutRect.size
        frameForNewSize(sizeBefore: before)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Keep the layer contentsScale in sync so the compositor never
        // rescales our IOSurface contents (upstream: HighResolutionOSX docs).
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface else { return }
        guard frame.size.width > 0, frame.size.height > 0 else { return }

        let fbFrame = convertToBacking(frame)
        ghostty_surface_set_content_scale(
            surface,
            fbFrame.size.width / frame.size.width,
            fbFrame.size.height / frame.size.height)

        if contentSize != .zero {
            let scaled = convertToBacking(contentSize)
            setSurfaceSize(width: UInt32(max(0, scaled.width)), height: UInt32(max(0, scaled.height)))
        }
    }

    /// Light or dark, for this terminal. Called by `GhosttyRuntime.syncColorScheme`
    /// and by nothing else: which of the two it is gets decided there, once,
    /// for every terminal. A hibernated view has no terminal to tell, and the
    /// one it wakes with starts from the app's scheme.
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    /// A second witness to a change of appearance, not a source of one: it
    /// asks for a sync, which reads the app's appearance and not this view's.
    /// A view's own `effectiveAppearance` also moves when a window is given
    /// an appearance of its own, and is not told at all outside a window,
    /// which is why upstream stopped deciding from it (ghostty PR #9360).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        runtime?.syncColorScheme(because: "a view's appearance changed", announced: true)
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window, let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen, let surface else { return }
        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    // MARK: - Actions from the runtime

    func cellSizeDidChange(backing: NSSize) {
        cellSize = convertFromBacking(backing)
        accessibilityWatch.outputArrived()
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        if !isCovered { cursor.set() }
    }

    func setCursorVisibility(_ visibility: ghostty_action_mouse_visibility_e) {
        switch visibility {
        case GHOSTTY_MOUSE_HIDDEN:
            if cursorVisible { NSCursor.hide(); cursorVisible = false }
        default:
            if !cursorVisible { NSCursor.unhide(); cursorVisible = true }
        }
    }

    override func resetCursorRects() {
        guard !isCovered else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        // Under a start's cover the program has not asked for bracketed
        // paste yet, so this would go in as typing, a Return per line. It
        // waits for the program's interface, and goes in after the keys
        // held with it; a start that ends any other way drops it.
        guard !isStarting else {
            return afterStart { [weak self] end in
                if end?.takesPaste == true { self?.performBinding("paste_from_clipboard") }
            }
        }
        performBinding("paste_from_clipboard")
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropPasteboard.hasInsertableContent(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropPasteboard.hasInsertableContent(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DropPasteboard.insertablePaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        // Trailing space so the user can keep typing a prompt after the path.
        sendText(paths.joined(separator: " ") + " ")
        return true
    }

    /// Write text straight to the surface, as a paste would. Not for keyDown —
    /// that path routes through `keyTextAccumulator` (see `insertText`).
    /// `scripted` for text no person typed (`onScriptedInput`).
    func sendText(_ string: String, scripted: Bool = false) {
        guard let surface else { return }
        let len = string.utf8CString.count
        guard len > 1 else { return }
        noteInput(scripted: scripted)
        string.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    /// Press Return, as the key: a press and a release through libghostty's
    /// key encoder, the same call `keyDown` ends in. Not a "\r" written to
    /// the pty, which is what Return *usually* encodes to: a program that
    /// turned on the kitty keyboard protocol, as agents do, is sent something
    /// else for the key, and reads a bare carriage return as a different
    /// key or as part of a paste. For `wortel send --enter`, so what reaches
    /// the program is what a person's Return would have been.
    @discardableResult
    func pressReturn(scripted: Bool) -> Bool {
        guard let surface else { return false }
        noteInput(scripted: scripted)
        var key = ghostty_input_key_s()
        key.keycode = 0x24 // kVK_Return
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        // Unshifted, Return types a carriage return. The text stays nil, as
        // `keyAction` leaves it for every control character: ghostty encodes
        // those itself.
        key.unshifted_codepoint = 0x0D
        key.text = nil
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        let handled = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
        return handled
    }

    /// Type a command line into the shell and run it, as if it had been typed
    /// and Enter pressed: raw into the pty, after ^E ^U to clear whatever was
    /// half-typed at the prompt (^E first, since fish's ^U only clears what's
    /// behind the cursor). Not `sendText`, which arrives as a bracketed paste:
    /// zsh puts a pasted newline in the line instead of running it. The same
    /// way `GhosttyRuntime` types a resume into a shell that survived. False
    /// when there's no pty to write to (the exec backend owns its own).
    @discardableResult
    func typeCommand(_ line: String) -> Bool {
        guard let pty = ptyHost else { return false }
        let bytes = Array(("\u{05}\u{15}" + line + "\n").utf8)
        bytes.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            pty.write(base, count: raw.count)
        }
        return true
    }

    @objc override func selectAll(_ sender: Any?) {
        performBinding("select_all")
        accessibilitySelectionMayHaveChanged()
    }

    @objc func increaseFontSize(_ sender: Any?) {
        performBinding("increase_font_size:1")
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        performBinding("decrease_font_size:1")
    }

    @objc func resetFontSize(_ sender: Any?) {
        performBinding("reset_font_size")
    }

    @discardableResult
    private func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        // Only a paste puts anything into the program. Copy, select all and
        // the font size are the user's doing and nothing the program sees.
        noteUserInput(text: action.hasPrefix("paste"))
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    /// The modifiers a pointer event carries into libghostty, with one
    /// addition: ⌘ held while the program has the mouse also counts as Shift.
    ///
    /// A fullscreen agent (Codex, Claude Code in its alternate screen) turns on
    /// mouse reporting and does its own selection from the reports. While it
    /// has the mouse, libghostty does not look for a link under the pointer at
    /// all unless Shift is held, Shift being the "terminal, not the program"
    /// override (`Surface.cursorPosCallback`). So ⌘-click on a URL did nothing:
    /// the click went to the program, which only follows the links it printed
    /// itself as OSC 8, and not the ones in an approval prompt or a command.
    /// Reported 2026-11-10 by a Codex user who could neither click nor copy a
    /// URL; ⇧⌘-click worked, which nobody knows to try. Treating ⌘ as Shift
    /// here makes ⌘-click open a link everywhere, and ⌘-drag a terminal
    /// selection, which is what both mean when the program isn't listening.
    /// A program never sees ⌘ in a mouse report anyway (no encoding has it).
    ///
    /// While the left button is down the decision is the one made at the
    /// press (`pressOverride`), whatever ⌘ or the program does meanwhile:
    /// letting go of ⌘ halfway through a ⌘-drag must not hand the program the
    /// rest of a drag and a release for a press it never saw.
    private func pointerMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        let mods = GhosttyInput.mods(flags)
        guard pressOverride ?? overridesShift(flags) else { return mods }
        return ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
    }

    /// ⌘ without Shift while the program has the mouse; see `pointerMods`.
    private func overridesShift(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), !flags.contains(.shift), let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// Tells libghostty where the pointer is again, with `mods`, so it looks
    /// for a link under it now. It only looks when the pointer moves, so a ⌘
    /// pressed (or a ⌘-click made) over a URL the pointer was already resting
    /// on otherwise found nothing. Two calls, because the embedded runtime
    /// drops a position within a pixel of the last one (macOS sends phantom
    /// moves): the first steps 1pt aside and the second comes back.
    private func refreshPointer(at pos: NSPoint, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        let y = frame.height - pos.y
        ghostty_surface_mouse_pos(surface, pos.x + (pos.x >= 1 ? -1 : 1), y, mods)
        ghostty_surface_mouse_pos(surface, pos.x, y, mods)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        noteUserInput(text: false)
        let override = overridesShift(event.modifierFlags)
        pressOverride = override
        commandPressPoint = event.modifierFlags.contains(.command)
            ? convert(event.locationInWindow, from: nil) : nil
        let mods = pointerMods(event.modifierFlags)
        // The ⌘ press before this click usually refreshed the link already
        // (`flagsChanged`), but not when it reached another view first.
        if override { refreshPointer(at: convert(event.locationInWindow, from: nil), mods: mods) }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        accessibilitySelectionMayHaveChanged()
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        defer { pressOverride = nil; commandPressPoint = nil }
        guard let surface else { return }
        let mods = pointerMods(event.modifierFlags)
        // A ⌘-click (not a drag): its rows are read now, before libghostty
        // handles the release and the program can draw over them. libghostty
        // opens a link at the release, inside this call, and its OPEN_URL
        // queues `openLink` on the main queue, which takes the rows. If it
        // found none, the check queued after it still has them: the click may
        // be on half a link an agent broke over rows, which libghostty's
        // one-row match can't see (`TerminalLinkWrap`).
        pendingLinkClick = nil
        let point = convert(event.locationInWindow, from: nil)
        // One click only: the second of a double-click would open it again.
        if event.modifierFlags.contains(.command), event.clickCount == 1,
           let press = commandPressPoint, sameCell(press, point) {
            pendingLinkClick = linkClick(at: point)
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        if let click = pendingLinkClick {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingLinkClick == click else { return }
                self.pendingLinkClick = nil
                self.onOpenLink?(TerminalLinkRequest(link: nil, tagged: false, click: click))
            }
        }
        ghostty_surface_mouse_pressure(surface, 0, 0)
        accessibilitySelectionMayHaveChanged()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        let mods = GhosttyInput.mods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        let mods = GhosttyInput.mods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS,
            GhosttyInput.mouseButton(fromButtonNumber: event.buttonNumber), mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE,
            GhosttyInput.mouseButton(fromButtonNumber: event.buttonNumber), mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // Ghostty expects top-left origin.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, pointerMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        // Off the pressed cell, a ⌘-press is a drag (a selection), even if it
        // comes back: not a click on a link.
        if let press = commandPressPoint, !sameCell(press, convert(event.locationInWindow, from: nil)) {
            commandPressPoint = nil
        }
        mouseMoved(with: event)
        accessibilitySelectionMayHaveChanged()
    }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseEntered(with event: NSEvent) {
        // Reset the position on entry; mouse-report logic depends on it.
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // mouse-hide-while-typing hides the cursor app-wide via NSCursor.hide().
        // Once the pointer leaves the surface, libghostty stops sending mouse
        // events and never fires the unhide, so the cursor would stay hidden
        // over the sidebar and the rest of the UI. Restore it on exit.
        if !cursorVisible { NSCursor.unhide(); cursorVisible = true }
        // If dragging we keep getting mouseDragged outside the view.
        if NSEvent.pressedMouseButtons != 0 { return }
        // Negative values tell ghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        noteUserInput(text: false)

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // 2x multiplier, subjective "feels better" from upstream.
            x *= 2
            y *= 2
        }

        ghostty_surface_mouse_scroll(
            surface, x, y,
            GhosttyInput.scrollMods(precision: precision, momentum: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        guard prevPressureStage < 2 else { return }
        prevPressureStage = event.stage
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        Self.onKeyboardActivity?(self)
        // Return under a start's cover was pressed at a screen nobody has
        // seen: it is not typed, and neither is what follows it
        // (`PtyHost.releaseTyping`). Caught as the key, before it is encoded.
        // Not while composing, where Return only settles the text being
        // composed.
        if isStarting, !hasMarkedText(), event.keyCode == 0x24 || event.keyCode == 0x4C { // Return, keypad Enter
            ptyHost?.cutHeldTyping()
            return
        }
        // Typing clears a selection, and a keybind can make one.
        accessibilitySelectionMayHaveChanged()
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods (handles option-as-alt configs). We check exact
        // states because hidden bits in the event matter for dead keys.
        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // MUST reuse the original event when mods are equal; AppKit object
        // identity keeps Korean input working (upstream comment).
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Non-nil accumulator marks that we're inside a keyDown; insertText
        // appends into it instead of sending text directly (Korean etc.).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        // Some key events change the keyboard layout (IME grabbing input);
        // those must not reach the terminal.
        let keyboardIdBefore: String? = markedTextBefore ? nil : KeyboardLayout.id

        // See lastPerformKeyEvent docs; interpretKeyEvents may redispatch.
        self.lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Composing also when preedit was just cleared: that input canceled
        // composition and must not be encoded (e.g. backspace or ⌃H during
        // Japanese composition must not delete what was typed before it).
        let composing = markedText.length > 0 || markedTextBefore

        // Every return below is taken only while composing, where no Return
        // counts, but a defer keeps that from being something to re-check.
        defer {
            if Self.isSubmit(keyCode: event.keyCode, modifiers: event.modifierFlags,
                             isRepeat: event.isARepeat, composing: composing) {
                onSubmit?()
            }
        }

        // The input method committed all or part of what it was composing,
        // with this key (Return, ⌃J or a space in Japanese input, the next
        // jamo or an arrow in Korean). The text goes as text alone, and the
        // key itself only when it still means something after the commit
        // (`KeyInputText.replaysKeyAfterCommit`). Sent with the key, as
        // before, a control key that committed could still be encoded as
        // itself after the text: ⌃J committing a Japanese word also sent the
        // program a line feed (Ghostty fa141a726, d60a16c14).
        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !KeyInputText.isComposingControl(text, composing: composing) {
                _ = committedTextAction(action, text: text)
            }
            if KeyInputText.replaysKeyAfterCommit(keyCode: translationEvent.keyCode,
                                                  modifiers: translationEvent.modifierFlags) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            // Composition produced text; composing is never true for these.
            // A bare control character the input method passed on while
            // composing is its own and is dropped (Ghostty a43cc02eb).
            for text in list where !KeyInputText.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // A control key while composing is the input method's: Japanese
            // input converts and edits with ⌃H ⌃J ⌃M ⌃N, and each also reached
            // the program as a backspace, a line feed or a Return (Ghostty
            // a43cc02eb).
            if KeyInputText.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event, entersText: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // Don't touch mods mid-preedit.
        if hasMarkedText() { return }

        let mods = GhosttyInput.mods(event.modifierFlags)

        // Press if this side's key is now down, else release.
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }

        _ = keyAction(action, event: event, entersText: false)

        // ⌘ going down over a link while the program has the mouse: the key
        // event above told libghostty ⌘ without the added Shift, so it would
        // show no link until the pointer moved. Releasing needs nothing, since
        // libghostty clears the link itself when the mods stop matching.
        if mod == GHOSTTY_MODS_SUPER.rawValue, action == GHOSTTY_ACTION_PRESS,
           pressOverride == nil, overridesShift(event.modifierFlags),
           let window {
            let pos = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pos) {
                refreshPointer(at: pos, mods: pointerMods(event.modifierFlags))
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard focused else { return false }
        guard let surface else { return false }

        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var bindingFlags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &bindingFlags)
        }

        // A performable binding is ghostty's, ahead of the menu: it acts only
        // when it can, and otherwise the key goes to the program, as in
        // Ghostty.app. That's ⌘C with nothing selected here, which is how
        // Codex in fullscreen copies the selection it draws itself; the menu's
        // Copy swallowed it. In legacy key encoding a ⌘ key sends nothing, so
        // a shell sees no difference.
        if isBinding, bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue != 0 {
            keyDown(with: event)
            return true
        }

        // Otherwise Wortel's menu wins over ghostty's default keybinds (both
        // usually agree, but the menu is the source of truth).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        // If ghostty considers this a binding, run it through keyDown.
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // C-/ as C-_ (avoids the system beep).
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"

        default:
            // Synthetic events (zero timestamp) are never processed here.
            if event.timestamp == 0 { return false }

            guard event.modifierFlags.contains(.command) ||
                  event.modifierFlags.contains(.control)
            else {
                lastPerformKeyEvent = nil
                return false
            }

            // Unclaimed command keys come back through doCommand which
            // re-sends the event; the timestamp match routes it to keyDown.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode)

        // Failable, and a nil here used to be a crash on a keypress. The same
        // construction in `keyDown` already falls back rather than forcing;
        // returning false is the honest answer, and AppKit carries on down the
        // responder chain.
        guard let finalEvent else { return false }
        keyDown(with: finalEvent)
        return true
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false,
        entersText: Bool = true
    ) -> Bool {
        guard let surface else { return false }
        // A key coming up is not text going in, and nor is a modifier on its
        // own. Counted as text, the release of the Return that sent a prompt
        // landed after the agent said `working`, and read as a prompt half
        // written for the whole of the turn that followed.
        noteUserInput(text: entersText && action != GHOSTTY_ACTION_RELEASE)

        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // No text that starts with a control character, DEL included:
        // ghostty encodes those itself (ctrl+enter etc); see `keyEventText`.
        if let text = KeyInputText.keyEventText(text) {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    /// Text an input method committed, as a key event carrying only the text:
    /// no key code, no modifiers. Through the key encoder, as typing goes,
    /// and not `ghostty_surface_text`, which is a paste: a program that
    /// switched bracketed paste on (Claude Code and Codex do) got macOS
    /// Dictation, the emoji picker and an input method's commit as a paste,
    /// and showed "[Pasted text]" where the words should have been typed
    /// (Ghostty 751a60df6, ecbeb60ca).
    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface, !text.isEmpty else { return false }
        noteUserInput()
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = 0
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }
}

// MARK: - NSTextInputClient

extension SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghosttyFreeText(&text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        // Outside a keyDown (e.g. layout switch mid-compose) sync immediately.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        // Dictation indicator wants zero width (upstream #8493).
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }

        // Ghostty is top-left origin; AppKit is bottom-left.
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        guard surface != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as NSString: chars = surrogates.text(for: v)
        default: return
        }

        // insertText means the preedit is over.
        unmarkText()

        // Inside a keyDown: accumulate, keyDown sends it with key info.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Outside a keyDown it is an input method with nothing to type it
        // with: Dictation, the emoji picker, a commit made with the mouse.
        // As typed text, never as a paste; see `committedTextAction`.
        _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars)
    }

    override func doCommand(by selector: Selector) {
        // Re-send unclaimed command events so keyDown can encode them
        // (see performKeyEquivalent / lastPerformKeyEvent).
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        // Everything else is swallowed, which keeps NSBeep away. This used to
        // run scroll_to_top for moveToBeginningOfDocument and scroll_to_bottom
        // for moveToEndOfDocument, taken for Home and End. They are ⌘↑ and
        // ⌘↓, which libghostty binds to the previous and next prompt: the
        // key's interpretation scrolled to the very top first, and from there
        // no prompt was above, so ⌘↑ went to the top of the scrollback.
        // ⌘Home and ⌘End are libghostty's own bindings and scroll without
        // this (Ghostty 30fdc8f4c).
    }

    /// Push the markedText state to libghostty as preedit text.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // -1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

extension NSScreen {
    /// CGDirectDisplayID for this screen (for ghostty_surface_set_display_id).
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
