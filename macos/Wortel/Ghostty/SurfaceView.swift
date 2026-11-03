import AppKit
import GhosttyKit

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
    var onNotification: ((_ title: String, _ body: String) -> Void)?
    /// A clicked link resolved to a local markdown file (decided in the runtime's
    /// OPEN_URL handler). The owner opens it in the right-hand preview. Non-markdown
    /// links never reach here — libghostty handles those itself.
    var onOpenMarkdown: ((_ url: URL) -> Void)?
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
    /// replies to its queries. A move waiting on the agent goes ahead only
    /// once this has been quiet a while.
    private(set) var lastUserInputAt: Date?

    /// Every input path reports here, so the time and the hook can't drift apart.
    private func noteUserInput() {
        lastUserInputAt = Date()
        onUserInput?()
    }

    private(set) var pwd: String?
    private(set) var focused: Bool = false

    // IME / preedit state (see keyDown for the dance).
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]? = nil
    private var lastPerformKeyEvent: TimeInterval?

    // Mouse state
    private var prevPressureStage: Int = 0
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

    /// Cached content size in points for backing-property changes (during
    /// animations the frame may lag the target size).
    private var contentSize: NSSize = .zero

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

    static func holdResizes() { resizeHolds += 1 }

    /// Shown again: take the size it missed while hidden, a moment later
    /// rather than now. A session switch unhides this before the new session's
    /// column has been applied, so the container is still the *previous*
    /// session's width at this instant; taken now, a terminal coming back to
    /// the width it left at would be resized to the other session's and back
    /// again, two redraws for nothing. A moment later the layout has landed,
    /// and usually it's the size it already had. Until then its last frame
    /// shows pinned top left, as during a hold.
    override var isHidden: Bool {
        didSet {
            guard oldValue, !isHidden, resizePending else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.resizePending, !self.isHidden, Self.resizeHolds == 0
                else { return }
                self.sizeDidChange(self.frame.size)
            }
        }
    }

    static func releaseResizes() {
        resizeHolds = max(0, resizeHolds - 1)
        guard resizeHolds == 0 else { return }
        NotificationCenter.default.post(name: resizeHoldReleased, object: nil)
    }

    @objc private func resizeHoldDidRelease(_ notification: Notification) {
        guard resizePending else { return }
        resizePending = false
        sizeDidChange(frame.size)
    }

    /// The pty, when this surface's shell belongs to the keeper rather than to
    /// libghostty's exec backend. Held here because the view's lifetime is the
    /// session's, and nothing else outlives both the surface and the shell.
    var ptyHost: PtyHost?

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
        guard let surface else { return true }
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
         environment: [String: String] = [:], fontSize: Float = 0) {
        self.runtime = runtime
        self.environment = environment

        // Non-zero initial frame so the renderer's layer bounds are non-zero.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        self.surface = runtime.newSurface(
            view: self,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            initialInput: initialInput,
            environment: environment,
            fontSize: fontSize)

        NotificationCenter.default.addObserver(
            self, selector: #selector(resizeHoldDidRelease(_:)),
            name: Self.resizeHoldReleased, object: nil)

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
        if let surface { ghostty_surface_free(surface) }
    }

    /// True when the surface still has a process running that ghostty thinks
    /// warrants a confirmation before closing (per `confirm-close-surface`).
    /// False once the child has exited, or before the shell has spawned.
    var needsConfirmClose: Bool {
        guard let surface else { return false }
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
        guard let surface, !processFinished else { return }
        processFinished = true
        ghostty_surface_process_exit(surface, 0, 0)
    }

    /// Explicit teardown (deinit ordering with AppKit view hierarchies is
    /// unreliable; call this when the session closes).
    func close() {
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
        // The pty's queue writes into this surface — the replay right after
        // it was created, then every read — so it is freed only once that
        // queue has nothing left to write. See `PtyHost.enqueue`.
        // `self` is held until then: the surface's userdata points at it.
        guard let pty else { return ghostty_surface_free(surface) }
        pty.enqueue {
            DispatchQueue.main.async {
                withExtendedLifetime(self) { ghostty_surface_free(surface) }
            }
        }
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
            // Freed only once the old pty's queue has nothing left to write
            // into it, as in `close`.
            if let pty {
                pty.enqueue { DispatchQueue.main.async { ghostty_surface_free(old) } }
            } else {
                ghostty_surface_free(old)
            }
        }

        surface = runtime.newSurface(view: self, workingDirectory: workingDirectory,
                                     sessionID: sessionID, initialInput: initialInput,
                                     environment: environment)
        guard let surface else { return }
        // What `viewDidMoveToWindow` and the host told the old surface, told
        // again: the screen, the scale and last real size, the appearance,
        // whether it is shown, and whether it has the keyboard.
        if let window { ghostty_surface_set_display_id(surface, window.screen?.displayID ?? 0) }
        viewDidChangeBackingProperties()
        viewDidChangeEffectiveAppearance()
        ghostty_surface_set_occlusion(surface, !isHidden)
        focused = false
        updateFocus()
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
        viewDidChangeEffectiveAppearance()
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
        if reflowed { onSizeChange?() }
        let scaled = convertToBacking(size)
        setSurfaceSize(width: UInt32(max(0, scaled.width)), height: UInt32(max(0, scaled.height)))
    }

    private func setSurfaceSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, width, height)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        let isDark = GhosttyRuntime.isDark(effectiveAppearance)
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
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
    func sendText(_ string: String) {
        guard let surface else { return }
        let len = string.utf8CString.count
        guard len > 1 else { return }
        noteUserInput()
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
    func pressReturn() -> Bool {
        guard let surface else { return false }
        noteUserInput()
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
        noteUserInput()
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

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        noteUserInput()
        let mods = GhosttyInput.mods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        guard let surface else { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
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
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
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
        noteUserInput()

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
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
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

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard focused else { return false }
        guard let surface else { return false }

        // Wortel's menu wins over ghostty's default keybinds (both usually
        // agree, e.g. super+c == copy, but the menu is the source of truth).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        // If ghostty considers this a binding, run it through keyDown.
        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var bindingFlags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &bindingFlags)
        }
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
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        noteUserInput()

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
        defer { ghostty_surface_free_text(surface, &text) }
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
        defer { ghostty_surface_free_text(surface, &text) }
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
