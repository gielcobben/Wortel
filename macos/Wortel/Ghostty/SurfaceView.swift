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
    /// A ⌘-clicked link that is a path, a `file:` URL or a server on this Mac,
    /// as libghostty matched it (`GhosttyRuntime`'s OPEN_URL handler). The
    /// owner resolves a path against this terminal's folders (`TerminalLink`)
    /// and opens it. Other web links never reach here: libghostty opens those.
    var onOpenLink: ((_ link: String) -> Void)?
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
    private var lastPerformKeyEvent: TimeInterval?

    // Mouse state
    private var prevPressureStage: Int = 0
    /// Whether the left press now held down took the ⌘-as-Shift override;
    /// nil while no left button is down. See `pointerMods`.
    private var pressOverride: Bool?
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
    private let isSessionTerminal: Bool

    private static let firstSizeKey = "terminal.lastShownSize"

    /// The size, in points, a session's terminal last had on screen, kept
    /// across launches. A new terminal starts at it rather than at
    /// libghostty's placeholder of 45 columns by 15 rows, because most are
    /// made out of sight (every session's at launch, a hibernated one when it
    /// wakes, a new session made from the command line) and an agent in one
    /// works at whatever width it is given. A terminal is never resized while
    /// hidden, so this first size is the one it works at until it is shown.
    private static var firstSize: NSSize? = {
        guard let stored = UserDefaults.standard.array(forKey: firstSizeKey) as? [Double],
              stored.count == 2, stored[0] >= 40, stored[1] >= 20 else { return nil }
        return NSSize(width: stored[0], height: stored[1])
    }()

    /// Held in memory as it changes, which during a window drag is every
    /// frame, and written to defaults once it has settled for a second.
    private static func rememberShownSize(_ size: NSSize) {
        guard size != firstSize else { return }
        firstSize = size
        saveFirstSize?.cancel()
        let work = DispatchWorkItem {
            saveFirstSize = nil
            UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: firstSizeKey)
        }
        saveFirstSize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static var saveFirstSize: DispatchWorkItem?

    /// A new surface that nothing has told a size yet (made out of sight, or
    /// woken without ever having been shown) is told `firstSize`. One that has
    /// been on screen was told its own last size by
    /// `viewDidChangeBackingProperties` already. With neither, it is told
    /// nothing, and its pty keeps the size it has (`PtyHost.ignoreSizesUntilTold`).
    private func tellFirstSize() {
        // What a new surface is told as it is set up is not the first step
        // of a drag: the size its view gives it next, however soon, gets its
        // frame in the same commit (`frameForNewSize`).
        defer { sizedAt = nil }
        guard isSessionTerminal, surface != nil, toldSize == nil, let size = Self.firstSize else { return }
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

    /// Set while this terminal is hibernated: its surface is gone, its shell
    /// is not. See `hibernate`.
    private(set) var hibernation: Hibernation?

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
        guard let surface else { return hibernation == nil || processFinished }
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
         isSessionTerminal: Bool = false) {
        self.runtime = runtime
        self.environment = environment
        self.isSessionTerminal = isSessionTerminal

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
            fontSize: fontSize)
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
        guard let surface else { return hibernation != nil && confirmCloseWhileHibernated }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Tell libghostty this terminal's process has exited, so it behaves as it
    /// does when an exec-backend shell exits: it says so on screen, stops
    /// asking for confirmation to close, and asks to close the surface unless
    /// configured to wait. Exit code 0 and no runtime, because the keeper
    /// reaped the shell and only the pty hanging up reached this side; a
    /// non-zero code would read as a crash at startup.
    ///
    /// Once per surface, and nothing at all once the surface is gone.
    func finishProcess() {
        guard !processFinished else { return }
        guard let surface else {
            // Hibernated: the terminal is told when it wakes (`wake`).
            if hibernation != nil { processFinished = true }
            return
        }
        processFinished = true
        ghostty_surface_process_exit(surface, 0, 0)
    }

    /// Explicit teardown (deinit ordering with AppKit view hierarchies is
    /// unreliable; call this when the session closes).
    func close() {
        discardHibernation()
        // Closing a *session* is the user saying they are done with it, so the
        // shell goes too — unlike quitting the app, which deliberately leaves it
        // running and is handled by the connection simply dropping.
        if let keeperSession {
            GhosttyRuntime.keeper?.close(session: keeperSession)
            // Its terminal's modes went with it.
            TerminalModeRecorder.shared.forget(session: keeperSession)
            ptyHost?.release() // the keeper owns the process; just let go
        } else {
            ptyHost?.stop()
        }
        keeperSession = nil
        let pty = ptyHost
        ptyHost = nil
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
    /// 2026-11-19), a step cost 7.4 ms with it and 5.0 without, and with a
    /// pane open beside the terminal most steps took longer than the 8.3 ms
    /// a frame lasts: the edge stood still.
    ///
    /// The frame it buys is rarely a new picture. The terminal re-wraps on
    /// its own thread after the size is told, so the frame drawn in the same
    /// commit mostly shows the screen as it was, which the layer does without
    /// being asked: it pins the frame it has to the top left at its own size
    /// (the padding does not move, `window-padding-balance` is off, and the
    /// background is not drawn at all, `background-opacity = 0`).
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
    func restartShell(workingDirectory: String?, sessionID: UUID, initialInput: String?) {
        guard let runtime else { return }
        discardHibernation()
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
        // shell, and a relaunch would otherwise replay it into one.
        TerminalModeRecorder.shared.forget(session: sessionID)
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

    // MARK: - Hibernation

    /// A hidden session can give back its terminal: the renderer's frames, the
    /// scrollback, the font atlas, about 70 MB a session (measured 2026-11-17).
    /// The shell and whatever runs in it carry on; the app keeps reading the
    /// pty, so nothing is asked of the keeper. The screen goes to a file as
    /// escape sequences, the output that arrives meanwhile into a bounded
    /// buffer, and both are written into a new terminal when it is shown.
    final class Hibernation {
        let snapshot: URL
        /// The grid the snapshot was taken at, its total lines with history,
        /// and the cursor: enough to put the cursor back where the program
        /// left it, which an agent's next repaint counts on.
        let columns: Int, rows: Int
        /// Empty rows under the last line with text: the dump leaves them out.
        let blankRowsAtBottom: Int
        let cursor: (row: Int, column: Int)?
        let fontSize: Float
        /// What came while there was no terminal. Only touched on the pty queue.
        let missed: MissedOutput

        init(snapshot: URL, columns: Int, rows: Int, blankRowsAtBottom: Int,
             cursor: (row: Int, column: Int)?, fontSize: Float, missed: MissedOutput) {
            self.snapshot = snapshot
            self.columns = columns
            self.rows = rows
            self.blankRowsAtBottom = blankRowsAtBottom
            self.cursor = cursor
            self.fontSize = fontSize
            self.missed = missed
        }
    }

    /// The pty queue's buffer for a session with no terminal. A class so the
    /// output closure and the hibernation share one; confined to that queue.
    final class MissedOutput: @unchecked Sendable {
        var buffer = ReplayBuffer(limit: HibernationPolicy.missedOutputLimit)
        /// Bytes kept since the terminal was last asked back
        /// (`HibernationPolicy.outrunning`). Asked once `buffer` is half
        /// full, and again at every sixteenth of it written after that: the
        /// answer changes when an agent that was resting starts a turn.
        var sinceAsked = 0
        /// The modes the program believed in at the moment its output turned
        /// away from the terminal: the ones that go with the snapshot. What
        /// it changed after is in `buffer`. Read on the pty queue at the
        /// switch, so the two meet exactly.
        var prelude: [UInt8] = []
        /// Raises what the terminal would have, and keeps it out of `buffer`.
        var scanner = SignalScanner()
    }

    var isHibernated: Bool { hibernation != nil }

    /// Hibernating: the output has been turned away from the terminal and the
    /// screen is about to be written out. Neither hibernated nor awake.
    private(set) var isHibernating = false

    /// Set while a screen dump is taken: libghostty hands the dump's path to
    /// the clipboard callback, which gives it here instead of the pasteboard.
    var screenFileCapture: ((String) -> Void)?

    /// Asked when the timer comes due: whoever owns the session may know a
    /// reason to keep the terminal (an agent that only the screen shows
    /// working). nil means yes.
    var mayHibernate: (() -> Bool)?

    /// `needsConfirmClose` for a terminal that isn't there to ask: what it
    /// said when it went, until the shell is seen back at its prompt.
    private var confirmCloseWhileHibernated = false

    /// Free this terminal, keeping its shell. Only a keeper session whose shell
    /// is alive: on the exec backend the terminal *is* the shell's parent.
    func hibernate() {
        guard let surface, let pty = ptyHost, let session = keeperSession,
              hibernation == nil, !isHibernating, !processFinished else {
            HibernationLog.log.debug("""
                not hibernating: surface \(self.surface != nil), pty \(self.ptyHost != nil), \
                keeper \(self.keeperSession != nil), hibernated \(self.hibernation != nil), \
                hibernating \(self.isHibernating), finished \(self.processFinished)
                """)
            return
        }
        isHibernating = true
        let missed = MissedOutput()
        let started = DispatchTime.now()
        // The output turns away from the terminal first, on the queue that
        // writes into it, so the screen written out below has everything that
        // went into the terminal and the buffer everything after.
        pty.enqueue { [weak self] in
            missed.prelude = TerminalModeRecorder.shared.modes(for: session).prelude
            let status = self?.programStatusWatch
            pty.onOutput = { [weak self, weak pty] bytes, count in
                TerminalModeRecorder.shared.feed(session: session, bytes: bytes, count: count)
                // Heard here as it is with a terminal. It stays in what is
                // kept: the terminal that comes back ignores it, and the
                // replay into that terminal is not listened to again.
                status?.output(bytes, count: count, pty: pty)
                var kept: [UInt8] = []
                kept.reserveCapacity(count)
                let signals = missed.scanner.scan(UnsafeBufferPointer(start: bytes, count: count),
                                                  now: DispatchTime.now().uptimeNanoseconds, output: &kept)
                kept.withUnsafeBufferPointer { raw in
                    guard let base = raw.baseAddress, raw.count > 0 else { return }
                    missed.buffer.append(base, count: raw.count)
                }
                missed.sinceAsked += kept.count
                if missed.buffer.count >= missed.buffer.limit / 2,
                   missed.sinceAsked >= max(1, missed.buffer.limit / 16) {
                    missed.sinceAsked = 0
                    DispatchQueue.main.async {
                        if let self { HibernationPolicy.shared.outrunning(self) }
                    }
                }
                guard !signals.isEmpty else { return }
                DispatchQueue.main.async { self?.raise(signals) }
            }
            // Nothing else is written into this terminal from here on, so its
            // palette can stand in for itself in the dump: each entry a marker
            // that is turned back into its index on waking, or the screen
            // would come back frozen in today's theme (`SnapshotPalette`).
            SnapshotPalette.install.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_write_buffer(surface, base, UInt(raw.count))
            }
            DispatchQueue.main.async {
                self?.finishHibernating(surface: surface, pty: pty, session: session,
                                        missed: missed, started: started)
            }
        }
    }

    private func finishHibernating(surface old: ghostty_surface_t, pty: PtyHost, session: UUID,
                                   missed: MissedOutput, started: DispatchTime) {
        isHibernating = false
        // Closed or restarted meanwhile: that already let the surface go.
        guard surface == old, ptyHost === pty else { return }

        // Shown again in the moment it took to get here: it stays awake, and
        // gets back what was held from it. Signals already raised from those
        // bytes are not in them.
        func stayAwake() {
            let live = GhosttyRuntime.liveOutput(surface: old, session: session, view: self)
            pty.enqueue {
                // Its own palette back first, in place of the markers.
                let held = SnapshotPalette.remove + missed.buffer.take() + missed.scanner.unfinished
                held.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return }
                    ghostty_surface_write_buffer(old, base, UInt(raw.count))
                }
                pty.onOutput = live
            }
        }
        guard isHidden || superview == nil else { return stayAwake() }

        // The cursor is read against the screen's bottom, so the view goes
        // there first; this terminal is about to go anyway.
        let bottom = "scroll_to_bottom"
        _ = bottom.withCString { ghostty_surface_binding_action(old, $0, UInt(bottom.utf8.count)) }

        var path: String?
        screenFileCapture = { path = $0 }
        let action = "write_screen_file:copy,vt"
        _ = action.withCString { ghostty_surface_binding_action(old, $0, UInt(action.utf8.count)) }
        screenFileCapture = nil

        guard let path else {
            HibernationLog.log.error("no screen dump for \(session.uuidString, privacy: .public); staying awake")
            return stayAwake()
        }

        let size = ghostty_surface_size(old)
        // The scale the surface was made at: `newSurface` and `wakeSurface`
        // take the window's, or the main screen's before there is a window.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cursor = Self.cursorCell(of: old, size: size, scale: scale)
        let fontSize = ghostty_surface_inherited_config(old, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
        confirmCloseWhileHibernated = ghostty_surface_needs_confirm_quit(old)
        let snapshot = Self.keepSnapshot(at: path, session: session)

        hibernation = Hibernation(
            snapshot: snapshot, columns: Int(size.columns), rows: Int(size.rows),
            blankRowsAtBottom: Self.blankRowsAtBottom(of: old, size: size),
            cursor: cursor, fontSize: fontSize, missed: missed)
        surface = nil
        focused = false
        ghostty_surface_free(old)
        retireLayer()

        let bytes = (try? FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? Int) ?? -1
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        HibernationLog.log.notice("""
            hibernated \(session.uuidString, privacy: .public): snapshot \(bytes) bytes, \
            \(size.columns)x\(size.rows), blank below \(self.hibernation?.blankRowsAtBottom ?? 0), \
            cursor \(cursor.map { "\($0.row),\($0.column)" } ?? "?", privacy: .public), \
            \(ms, format: .fixed(precision: 1)) ms
            """)
    }

    /// Bring back a hibernated terminal: a new surface around the same pty,
    /// the snapshot and the missed output written into it, then the live
    /// output switched back. Called before the view is shown.
    ///
    /// `onRestored` runs on the main thread once the screen is back *and* the
    /// terminal has stopped holding back what it sends the program
    /// (`ReplayAnswers`): a key typed before then is dropped with the
    /// answers, so a host shows the terminal only after it.
    func wake(onRestored: (() -> Void)? = nil) {
        guard let hibernation, let runtime, let pty = ptyHost, let session = keeperSession else {
            onRestored?()
            return
        }
        let started = DispatchTime.now()
        guard let new = runtime.wakeSurface(view: self, pty: pty, fontSize: hibernation.fontSize) else {
            HibernationLog.log.error("could not wake \(session.uuidString, privacy: .public)")
            onRestored?()
            return
        }
        self.hibernation = nil
        isRestoring = true
        surface = new
        // A new terminal: whatever the old one was told, this one wasn't.
        toldSize = nil
        layerReplaced()
        if let window { ghostty_surface_set_display_id(new, window.screen?.displayID ?? 0) }
        viewDidChangeBackingProperties()
        tellFirstSize()
        runtime.syncColorScheme(because: "a terminal woke")
        ghostty_surface_set_occlusion(new, !isHidden)
        updateFocus()

        let live = GhosttyRuntime.liveOutput(surface: new, session: session, view: self)
        let dark = GhosttyRuntime.systemIsDark
        let created = DispatchTime.now()
        // The grid it has just been told, which is the one it went away with:
        // what was kept for it was drawn for that grid and no other.
        let told = toldSize == nil ? nil : Optional(ghostty_surface_size(new))
        // On the pty queue, as every write into a terminal is: the parser
        // waits on the main thread for room, so the main thread must not be
        // the one writing (the beach ball of 2026-10-07).
        pty.enqueue { [weak self] in
            let missed = hibernation.missed
            // Nothing goes in before the terminal is that size. See `waitForGrid`.
            var gridMs = 0.0
            if let told {
                let wait = Self.waitForGrid(new, columns: Int(told.columns), rows: Int(told.rows))
                gridMs = wait.ms
                if !wait.reached {
                    HibernationLog.log.notice("""
                        \(session.uuidString, privacy: .public) is written back at \
                        \(wait.grid.map { "\($0.columns)x\($0.rows)" } ?? "an unknown grid", privacy: .public), \
                        not the \(told.columns)x\(told.rows) it was told: what it missed may land wrong
                        """)
                }
            }
            var paletteColours = 0
            let snapshot = SnapshotPalette.restoringIndices(
                Self.withoutColourSettings((try? Data(contentsOf: hibernation.snapshot)) ?? Data()),
                restored: &paletteColours)
            // The snapshot, the empty rows and cursor it leaves out, what came
            // since, and last a sequence the output was in the middle of, for
            // the live output to finish.
            var replay = snapshot
            replay.append(contentsOf: Self.cursorRestore(snapshot: snapshot, hibernation: hibernation))
            let held = missed.buffer.take()
            replay.append(held)
            replay.append(contentsOf: missed.scanner.unfinished)
            GhosttyRuntime.restore(surface: new, pty: pty, session: session, prelude: missed.prelude,
                                   replay: replay, recordReplay: false, muteAnswers: true,
                                   colorScheme: (dark: dark, agent: nil))
            pty.onOutput = live
            try? FileManager.default.removeItem(at: hibernation.snapshot)

            let done = DispatchTime.now()
            let createMs = Double(created.uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let writeMs = Double(done.uptimeNanoseconds - created.uptimeNanoseconds) / 1e6
            HibernationLog.log.notice("""
                woke \(session.uuidString, privacy: .public): surface \(createMs, format: .fixed(precision: 1)) ms, \
                its size after \(gridMs, format: .fixed(precision: 1)) ms, \
                restore \(snapshot.count) + \(held.count) bytes in \(writeMs - gridMs, format: .fixed(precision: 1)) ms, \
                \(paletteColours) palette colours
                """)

            DispatchQueue.main.async {
                guard let self else {
                    onRestored?()
                    return
                }
                // The shell ended while there was no terminal to tell.
                if self.processFinished, self.surface == new { ghostty_surface_process_exit(new, 0, 0) }
                self.whenPasteReachesProgram(within: Self.restorePatience) { _ in
                    if self.surface == new { self.isRestoring = false }
                    onRestored?()
                    // It came back at the size it went away with. If its
                    // view changed meanwhile and nothing noted it (it joined
                    // the window with no terminal to tell), this does.
                    self.reconcileSize("woken")
                }
            }
        }
    }

    /// The grid a terminal has, asked of the terminal: where its cursor ends
    /// up when sent to the far corner, counted in cells by sending it one
    /// cell from home first. `ghostty_surface_size` is no answer to this: it
    /// is worked out from the size the surface was last *told*, at once,
    /// while the terminal takes that size on libghostty's IO thread some 25 ms
    /// later (it gathers resizes for that long). On a terminal nothing has
    /// been written into, which it leaves as it found it, cursor at home.
    private static func actualGrid(of surface: ghostty_surface_t) -> (columns: Int, rows: Int)? {
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
    /// half. Found with `scripts/try-hibernate-screen.sh` on 2026-11-19: an
    /// agent woken as it began to write had 3 lines of 120 missing and 18
    /// left over, with nothing lost, and its status line cut at exactly
    /// column 45. It is also what a session looked like when it was shown
    /// mid-turn after a hibernation.
    ///
    /// Asked every millisecond, for a quarter of a second at the most: the
    /// size lands after about 25 ms. Only this session's queue waits.
    private static func waitForGrid(
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

    /// Woken, and the screen not yet all back. Reading it now reads part of it.
    private(set) var isRestoring = false

    /// The longest a wake waits for the terminal to stop holding back its
    /// answers before calling itself done.
    private static let restorePatience: TimeInterval = 2

    /// What the terminal would have told the app, told by the scanner instead:
    /// the same callbacks, so nothing downstream knows the difference.
    private func raise(_ signals: [SignalScanner.Signal]) {
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

    /// Forget a hibernation without waking: the session closed or its shell
    /// was replaced. The buffer goes with the object; the file is removed.
    private func discardHibernation() {
        guard let hibernation else { return }
        self.hibernation = nil
        try? FileManager.default.removeItem(at: hibernation.snapshot)
    }

    /// The cursor's cell, from the IME point. libghostty gives the middle of
    /// the cursor's cell across and its bottom edge down, padding included,
    /// in points. The left padding is where column 0 starts (`tl_px_x` of a
    /// read at 0,0); the top padding is what is left over after whole cells.
    private static func cursorCell(of surface: ghostty_surface_t, size: ghostty_surface_size_s,
                                   scale: CGFloat) -> (row: Int, column: Int)? {
        let cellWidth = Double(size.cell_width_px) / Double(scale)
        let cellHeight = Double(size.cell_height_px) / Double(scale)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        let origin = ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0)
        var text = ghostty_text_s()
        var paddingLeft = 0.0
        if ghostty_surface_read_text(surface, ghostty_selection_s(top_left: origin, bottom_right: origin,
                                                                  rectangle: false), &text) {
            paddingLeft = max(0, text.tl_px_x)
            ghosttyFreeText(&text)
        }
        let paddingTop = y.truncatingRemainder(dividingBy: cellHeight)

        let column = Int(((x - paddingLeft - cellWidth / 2) / cellWidth).rounded())
        let row = Int(((y - paddingTop) / cellHeight).rounded()) - 1
        guard row >= 0, column >= 0 else { return nil }
        return (min(row, Int(size.rows) - 1), min(column, Int(size.columns) - 1))
    }

    /// After the snapshot: the empty rows it left off the bottom, as line
    /// feeds, so the screen stands where it stood, then the cursor where it
    /// was. A line feed at the bottom scrolls; above it, it only moves down.
    private static func cursorRestore(snapshot: Data, hibernation: Hibernation) -> [UInt8] {
        var bytes = Array("\u{1B}[0m".utf8)
        bytes += Array(repeating: 0x0A, count: hibernation.blankRowsAtBottom)
        if let cursor = hibernation.cursor {
            bytes += Array("\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8)
        }
        return bytes
    }

    /// How many rows at the bottom of the screen (not the scrolled view) are
    /// empty. Read one row at a time from the bottom; it stops at text.
    private static func blankRowsAtBottom(of surface: ghostty_surface_t, size: ghostty_surface_size_s) -> Int {
        let rows = Int(size.rows), columns = Int(size.columns)
        var blank = 0
        for row in stride(from: rows - 1, through: 0, by: -1) {
            func point(_ x: Int) -> ghostty_point_s {
                ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT,
                                x: UInt32(x), y: UInt32(row))
            }
            var text = ghostty_text_s()
            let region = ghostty_selection_s(top_left: point(0), bottom_right: point(max(0, columns - 1)),
                                             rectangle: false)
            guard ghostty_surface_read_text(surface, region, &text) else { break }
            let empty = text.text_len == 0 || (text.text.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
                    .allSatisfy(\.isWhitespace)
            } ?? true)
            ghosttyFreeText(&text)
            guard empty else { break }
            blank += 1
        }
        return blank
    }

    /// The dump opens by setting the terminal's foreground and background
    /// colours (OSC 10, 11) to the theme's at the time. Written back they
    /// would pin them, and the next light/dark switch would not reach this
    /// terminal. Only the run of OSC sequences at the very start goes.
    static func withoutColourSettings(_ dump: Data) -> Data {
        var index = dump.startIndex
        while index + 1 < dump.endIndex, dump[index] == 0x1B, dump[index + 1] == 0x5D {
            var end = index + 2
            var terminated = false
            while end < dump.endIndex {
                if dump[end] == 0x07 { end += 1; terminated = true; break }
                if dump[end] == 0x1B, end + 1 < dump.endIndex, dump[end + 1] == 0x5C { end += 2; terminated = true; break }
                end += 1
            }
            guard terminated else { break }
            index = end
        }
        return dump.subdata(in: index..<dump.endIndex)
    }

    /// Move libghostty's temporary dump into the data folder, readable by this
    /// user only. Where it stands if that fails.
    private static func keepSnapshot(at path: String, session: UUID) -> URL {
        let source = URL(fileURLWithPath: path)
        let folder = DataDirectory.file("hibernated")
        let destination = folder.appendingPathComponent("\(session.uuidString).vt")
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            // libghostty makes a directory per dump. `rmdir` takes it only
            // if it is empty, so a shared temporary folder is never touched.
            _ = rmdir(source.deletingLastPathComponent().path)
            return destination
        } catch {
            return source
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
        if let window {
            center.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowKeyStateChanged(_:)),
                               name: NSWindow.didResignKeyNotification, object: window)
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
        // size is current when it's shown again (`isHidden` below).
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
            if isSessionTerminal, window != nil { Self.rememberShownSize(size) }
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
        let mods = pointerMods(event.modifierFlags)
        // The ⌘ press before this click usually refreshed the link already
        // (`flagsChanged`), but not when it reached another view first.
        if override { refreshPointer(at: convert(event.locationInWindow, from: nil), mods: mods) }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        accessibilitySelectionMayHaveChanged()
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        defer { pressOverride = nil }
        guard let surface else { return }
        let mods = pointerMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
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

        if let list = keyTextAccumulator, !list.isEmpty {
            // Composition produced text; composing is never true for these.
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                // Composing also when preedit was just cleared: that input
                // canceled composition and must not be encoded (e.g. backspace
                // during Japanese composition).
                composing: markedText.length > 0 || markedTextBefore)
        }
        if Self.isSubmit(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                         composing: markedTextBefore || markedText.length > 0) {
            onSubmit?()
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

        // Only encode UTF-8 text when it's not a single control character;
        // ghostty encodes control characters itself (ctrl+enter etc).
        if let text, !text.isEmpty, let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
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
        guard let surface else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
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

        let len = chars.utf8CString.count
        guard len > 1 else { return }
        noteUserInput()
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
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

        // Native scroll commands (Home/End).
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)):
            performBinding("scroll_to_top")
        case #selector(moveToEndOfDocument(_:)):
            performBinding("scroll_to_bottom")
        default:
            // Swallow everything else: prevents NSBeep for unhandled actions.
            break
        }
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
