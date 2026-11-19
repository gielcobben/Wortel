import AppKit
import GhosttyKit
import os

/// Owns the libghostty process state: ghostty_init, the config, the app
/// handle, tick scheduling, and the runtime callbacks.
///
/// Threading: libghostty may invoke callbacks from its IO/render threads.
/// Callbacks copy any C-pointer data synchronously, then hop to the main
/// thread for anything that touches AppKit. Everything Wortel owns runs on
/// the main thread.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!
    private let config: ghostty_config_t
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    /// Whether an appearance is a dark one, and what the app's is right now.
    ///
    /// One definition and one source on purpose: `NSApp.effectiveAppearance`.
    /// Everything that tells a terminal or a program light or dark asks here
    /// (`syncColorScheme`, and the catch-up report a resumed or woken session
    /// gets), because a program is only ever told one thing, so they have to
    /// agree. Never a view's own `effectiveAppearance`, and never the
    /// `AppleInterfaceStyle` default: see `docs/appearance.md`.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static var systemIsDark: Bool { isDark(NSApplication.shared.effectiveAppearance) }

    /// Every terminal view there is, in a window or not, hibernated or not.
    /// Weak: a view leaves by going away.
    private let surfaceViews = NSHashTable<SurfaceView>.weakObjects()
    /// What the terminals were last told, to say in the log what changed.
    private var toldDark: Bool?
    private static let appearanceLog = Logger(subsystem: "com.gielcobben.Wortel", category: "appearance")

    init?() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            return nil
        }

        // -- Config: the bundled wortel.conf only ------------------------------
        // Never ghostty_config_load_default_files (the user's real
        // ~/.config/ghostty must not leak in) and never load_cli_args (on
        // macOS it reads NSProcessInfo.arguments, i.e. Xcode debug flags).
        guard let config = ghostty_config_new() else { return nil }
        if let confPath = Bundle.main.path(forResource: "wortel", ofType: "conf") {
            ghostty_config_load_file(config, confPath)
        } else {
            assertionFailure("wortel.conf missing from bundle")
        }
        ghostty_config_finalize(config)
        self.config = config

        #if DEBUG
        let diagCount = ghostty_config_diagnostics_count(config)
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(config, i)
            let message = diag.message.map { String(cString: $0) } ?? "?"
            NSLog("ghostty config diagnostic: %@", message)
        }
        assert(diagCount == 0, "invalid hardcoded ghostty config; see log")
        #endif

        // -- App ---------------------------------------------------------------
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            // May fire on any thread. Tick pumps app-level mailbox work only;
            // rendering runs on Ghostty's own threads.
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { ghostty_app_tick(runtime.app) }
        }
        runtimeConfig.action_cb = { app, target, action in
            GhosttyRuntime.handleAction(app: app, target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Synchronous by contract: fetch pasteboard text and complete.
            guard location == GHOSTTY_CLIPBOARD_STANDARD,
                  let view = GhosttyRuntime.surfaceView(fromUserdata: userdata),
                  let surface = view.surface
            else { return false }
            let pasteboard = NSPasteboard.general
            // Text wins; otherwise paste an image/file as its path so agents
            // receive pasted screenshots (matches drag & drop).
            let payload: String?
            if let string = pasteboard.string(forType: .string) {
                payload = string
            } else {
                let paths = DropPasteboard.insertablePaths(from: pasteboard)
                payload = paths.isEmpty ? nil : paths.joined(separator: " ")
            }
            guard let payload else { return false }
            payload.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, string, state, _ in
            // Auto-approved, deliberately. libghostty raises this for a paste
            // that looks unsafe — most often one carrying a newline, i.e. text
            // that could execute on arrival. The prompt is the right default for
            // a general terminal and the wrong one here: Wortel exists to sit
            // beside an agent, pasting multi-line output into a prompt is the
            // central gesture, and a confirmation on every one of them trains
            // the reflex that makes the warning useless anyway.
            //
            // What makes that affordable is that the clipboard is only ever
            // filled by something the user already ran. If Wortel ever grows a
            // path that writes the clipboard from remote content, this decision
            // has to be revisited rather than inherited.
            guard let view = GhosttyRuntime.surfaceView(fromUserdata: userdata),
                  let surface = view.surface, let string
            else { return }
            ghostty_surface_complete_clipboard_request(surface, string, state, true)
        }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, _ in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
            // Find the text/plain entry and copy it out before returning.
            for i in 0..<len {
                let item = content[i]
                guard let mime = item.mime, let data = item.data,
                      String(cString: mime) == "text/plain" else { continue }
                let string = String(cString: data)
                // A screen dump for hibernation: libghostty's only way to say
                // where it wrote the file is to "copy" the path. It goes to the
                // view that asked, never to the pasteboard.
                if let view = GhosttyRuntime.surfaceView(fromUserdata: userdata),
                   let capture = view.screenFileCapture {
                    capture(string)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(string, forType: .string)
                return
            }
        }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let view = GhosttyRuntime.surfaceView(fromUserdata: userdata) else { return }
            DispatchQueue.main.async { view.onCloseRequest?() }
        }

        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        guard let appHandle = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            return nil
        }
        self.app = appHandle

        // -- App-level focus + keyboard layout forwarding ----------------------
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ghostty_app_set_focus(self.app, true)
            self.syncColorScheme(because: "became active")
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ghostty_app_set_focus(self.app, false)
        })
        observers.append(center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ghostty_app_keyboard_changed(self.app)
        })

        // -- Light and dark ----------------------------------------------------
        // The app's appearance is the one notice; `syncColorScheme` does the
        // telling. The rest are second looks at moments a notice could have
        // been missed. macOS on Auto changes appearance only once the Mac has
        // been idle a while, which is as the display sleeps or the screen
        // locks, so the first thing that happens after a change is often one
        // of these. None is known to be needed; each costs a comparison.
        syncColorScheme(because: "launch")
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            if Thread.isMainThread {
                self?.syncColorScheme(because: "the appearance changed", announced: true)
            } else {
                DispatchQueue.main.async {
                    self?.syncColorScheme(because: "the appearance changed", announced: true)
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason) in [
            (NSWorkspace.didWakeNotification, "the Mac woke"),
            (NSWorkspace.screensDidWakeNotification, "the display woke"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "the user was switched back to"),
        ] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.syncColorScheme(because: reason)
            })
        }
        // Unlocking is not one of NSWorkspace's: `sessionDidBecomeActive` is
        // fast user switching. The login window says it to everyone.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.syncColorScheme(because: "the screen was unlocked") }

        // Prime the mailbox once.
        ghostty_app_tick(appHandle)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        ghostty_app_free(app)
        ghostty_config_free(config)
    }

    // MARK: - Light and dark

    /// A terminal view exists. From here on it is told light or dark with the
    /// rest, whether or not it is ever in a window.
    func register(_ view: SurfaceView) {
        surfaceViews.add(view)
    }

    /// Tell libghostty light or dark: the app, and every terminal there is.
    ///
    /// **The only place that does.** Light and dark used to reach a terminal
    /// by two roads: the app's appearance told the app handle, and each view's
    /// `viewDidChangeEffectiveAppearance` told its own surface. Two roads
    /// arrive at different times and one of them doesn't go everywhere:
    ///
    /// - A view that is not in a window is never told. Every session gets a
    ///   terminal at launch and joins the window only when first shown, so
    ///   after a change every session not yet looked at kept the old theme
    ///   and its program was never told (measured 2026-11-19).
    /// - The app road came first and re-applied the config to surfaces that
    ///   still held the old scheme, so every program that listens (`?2031`)
    ///   was first sent a report naming the *old* theme, and asked the
    ///   terminal for a background that had not changed yet. Then came two
    ///   reports for the new one. Upstream has the same (discussion #15116).
    ///
    /// So: one source (`systemIsDark`), one list (every view registers), and
    /// the app-level reload does not touch the surfaces (`handleAction`,
    /// `GHOSTTY_ACTION_RELOAD_CONFIG`). Each surface is told once, takes its
    /// new colours and then reports them, in that order.
    ///
    /// Safe to call at any time and as often as wanted: libghostty does
    /// nothing for a scheme it already has. That is what lets everything that
    /// might have missed a change simply call this.
    ///
    /// `announced` is for the log only: whether AppKit said the appearance
    /// changed, or this is a second look that may find it has.
    func syncColorScheme(because reason: String, announced: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        let dark = Self.systemIsDark
        let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        // The app first: a terminal made from here on starts from it.
        ghostty_app_set_color_scheme(app, scheme)
        let views = surfaceViews.allObjects
        for view in views { view.setColorScheme(scheme) }

        guard dark != toldDark else { return }
        let was = toldDark
        toldDark = dark
        guard let was else { return }
        let change = "\(was ? "dark" : "light") to \(dark ? "dark" : "light")"
        if announced {
            Self.appearanceLog.notice("\(change, privacy: .public): \(views.count) terminals told")
        } else {
            // A change nobody announced, found by looking. Worth knowing
            // about: it is the case the second looks exist for.
            Self.appearanceLog.error("""
                \(change, privacy: .public) without a notice, found because \(reason, privacy: .public): \
                \(views.count) terminals told
                """)
        }
        // After every terminal has been told: what an agent drew before this
        // is in the other appearance's colours now (`SessionManager`).
        NotificationCenter.default.post(name: Self.appearanceDidChange, object: self)
    }

    /// Light and dark changed, and every terminal has been told. Not posted
    /// for the first look at launch, which changes nothing.
    static let appearanceDidChange = Notification.Name("WortelAppearanceDidChange")

    /// What the terminals were last told. `systemIsDark` before the first
    /// look.
    var isDark: Bool { toldDark ?? Self.systemIsDark }

    // MARK: - Surface creation

    /// Create a new surface attached to `view`. The view is the surface
    /// userdata for all callbacks.
    /// `environment` is added to the shell's (the session's port block).
    func newSurface(view: SurfaceView, workingDirectory: String? = nil,
                    sessionID: UUID? = nil, initialInput: String? = nil,
                    environment: [String: String] = [:],
                    fontSize: Float = 0) -> ghostty_surface_t? {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0))
        cfg.font_size = fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // libghostty copies these into the surface during the _new call, so the
        // C strings only need to outlive that call — strdup here, free after.
        var allocations: [UnsafeMutablePointer<CChar>] = []
        func dup(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            allocations.append(p)
            return UnsafePointer(p)
        }
        defer { allocations.forEach { free($0) } }

        if let workingDirectory { cfg.working_directory = dup(workingDirectory) }
        // Auto-run a resume command (e.g. "claude --continue") in a restored
        // session whose agent was still running at quit. Fed as startup input.
        if let initialInput { cfg.initial_input = dup(initialInput) }

        // Tag the shell so the bundled integration can key its agent marker file
        // to this session (see AgentResumeStore).
        var envVars: [ghostty_env_var_s] = []
        if let sessionID {
            envVars.append(ghostty_env_var_s(
                key: dup("WORTEL_SESSION_ID"), value: dup(sessionID.uuidString)))
        }
        // Where the bundled `wortel` command lives. The shell integration reads
        // this and prepends it to PATH (see the zsh copy) — which is the whole
        // installation story: nothing to install, no installer to write, and the
        // command sits exactly where all of its use is.
        //
        // **A variable of our own rather than an override of PATH**, and that is
        // not a style choice. Setting `PATH` here does nothing: env_vars can only
        // *add* to the environment libghostty hands the shell, so a key that
        // already exists keeps its inherited value. The symptom was subtle —
        // `wortel` still resolved, to the app's own executable in Contents/MacOS,
        // because upstream's shell integration appends that directory and the
        // disk is case-insensitive. Typing the command launched a second Wortel.
        if let directory = Self.commandLineToolDirectory {
            envVars.append(ghostty_env_var_s(key: dup("WORTEL_BIN_DIR"), value: dup(directory)))
        }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            envVars.append(ghostty_env_var_s(key: dup(key), value: dup(value)))
        }

        // Process survival, and the default: ask the keeper for this session's
        // pty. If it already has one the shell outlived the last quit and we are
        // picking it back up; if not, the keeper forks a fresh one. Either way
        // the process belongs to the keeper rather than to us, which is the
        // whole point — quitting Wortel closes a window instead of killing
        // whatever your agents were in the middle of.
        //
        // **No keeper means the exec backend, unchanged.** Not a local fork:
        // when survival is unavailable the right thing is the path this app has
        // always used, with libghostty doing its own spawning and its own shell
        // integration. A missing helper should cost you survival and nothing
        // else.
        if let sessionID, let keeper = Self.keeper {
            guard let attachment = keeper.attachOrOpen(
                session: sessionID, plan: Self.shellPlan(sessionID: sessionID, environment: environment),
                // Home when none was given, as `wortel.conf`'s
                // `working-directory = home` gives the exec backend. Left nil,
                // the shell inherits the keeper's own directory, which is `/`
                // for anything launchd or the Finder started.
                workingDirectory: workingDirectory ?? NSHomeDirectory(), initialInput: initialInput,
                columns: 80, rows: 24)
            else {
                // **A keeper that would not hand this session over is not a
                // keeper without it.** "Attached elsewhere", a timeout, a
                // connection out of step: the session's shell may be alive in
                // there with its agent still running. The exec backend still
                // gives this terminal a shell, but typing the resume into it
                // would start a second agent on the same conversation.
                let droppedResume = cfg.initial_input != nil
                cfg.initial_input = nil
                view.initialInputDropped = droppedResume
                KeeperLog.log.error("""
                    keeper did not give session \(sessionID.uuidString, privacy: .public) its shell; \
                    starting one without the keeper\
                    \(droppedResume ? ", and without typing its resume" : "", privacy: .public)
                    """)
                return newExecSurface(config: &cfg, environment: &envVars)
            }
            // The resume is typed by the keeper when it forks the shell, so
            // libghostty must not type it a second time. A session that never
            // died has, as a rule, nothing to resume either — with one
            // exception: the shell survived but the agent in it did not, and
            // the shell sits idle at a prompt. On 2026-10-07 that was nine
            // sessions out of ten, and a restart of the app could never bring
            // them back because "the shell is alive" was read as "the agent
            // is". Only then is the resume typed into the surviving shell,
            // after its replay, and only on the keeper's word that the first
            // one went in; see `Attachment.resumeIsOwed`.
            var resumeAgain: String?
            if attachment.resumed, let initialInput,
               attachment.resumeIsOwed(table: Self.recentProcessTable) {
                NSLog("wortel: shell %d of session %@ is idle without its agent; resuming it again",
                      attachment.pid, sessionID.uuidString)
                // ^U first: whatever was left half-typed at that prompt is
                // cleared rather than prefixed to the command.
                resumeAgain = "\u{15}" + initialInput
            }
            // A keeper too old to know `initialInput` drops it and says
            // nothing; then libghostty types it into the fresh shell, as it
            // did before the keeper could. A survived shell never gets it here.
            if attachment.resumed || attachment.inputDelivered { cfg.initial_input = nil }
            return hostManagedSurface(view: view, config: &cfg, attachment: attachment,
                                      keeperPID: keeper.keeperPID, resumeAgain: resumeAgain)
        }

        return newExecSurface(config: &cfg, environment: &envVars)
    }

    /// A surface whose shell libghostty spawns itself: the exec backend.
    private func newExecSurface(
        config cfg: inout ghostty_surface_config_s, environment envVars: inout [ghostty_env_var_s]
    ) -> ghostty_surface_t? {
        envVars.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                cfg.env_vars = base
                cfg.env_var_count = buf.count
            }
            return ghostty_surface_new(app, &cfg)
        }
    }

    /// Build a surface around a pty the keeper owns.
    ///
    /// The order is the fiddly part: the two `receive_*` callbacks have to be in
    /// the config *before* `ghostty_surface_new`, so the pty wrapper must exist
    /// first — but nothing may be read until there is a surface to put it in,
    /// and the replay has to land before anything newer. Hence: wrap, create,
    /// wire, replay, and only then start reading.
    private func hostManagedSurface(
        view: SurfaceView, config cfg: inout ghostty_surface_config_s,
        attachment: KeeperConnection.Attachment, keeperPID: pid_t?, resumeAgain: String? = nil
    ) -> ghostty_surface_t? {
        let session = attachment.session
        let pty = PtyHost(adopting: attachment.descriptor)
        view.ptyHost = pty // the view's lifetime is the session's
        view.programStatusWatch.reset()
        view.keeperSession = attachment.session
        view.keeperPID = keeperPID
        // The keeper forked the shell, so it is the only one that knows the pid.
        // Everything the session goes on to run hangs off it.
        view.shellPID = attachment.pid > 0 ? attachment.pid : nil
        // A session that survived a relaunch: this terminal is new and holds
        // nothing but what the keeper buffered while the app was gone, which
        // for a program that sat idle is nothing at all. Left alone the window
        // is blank until you touch it, so the program is made to repaint once
        // it has a size (`PtyHost.ignoreSizesUntilTold`). A new session has
        // nothing to repaint and isn't asked.
        Self.hostManaged(&cfg, pty: pty, repaint: attachment.resumed)

        guard let surface = ghostty_surface_new(app, &cfg) else {
            NSLog("wortel: host-managed surface could not be created")
            return nil
        }

        pty.onOutput = Self.liveOutput(surface: surface, session: session, view: view)
        // The shell ended. The keeper reaps it, so its exit code is the
        // keeper's; what reaches this side is the pty hanging up. Whoever owns
        // the session decides what that means, and without an owner the
        // terminal is told directly, as the exec backend's would have been.
        //
        // Only for the pty the view still has: `restartShell` can give it a
        // new one while this hop is on its way, and that terminal's shell has
        // only just started. Weak, because the pty holds this closure.
        pty.onHangup = { [weak view, weak pty] in
            DispatchQueue.main.async {
                guard let view, let pty, view.ptyHost === pty else { return }
                if let shellEnded = view.onShellEnded { shellEnded() } else { view.finishProcess() }
            }
        }

        // The modes first, then the replay, then read.
        //
        // The shell survived and the program in it never restarted, so it still
        // believes every mode it ever set. This terminal is new and believes
        // none of them, and the first thing that disagreement costs is a paste:
        // without `?2004` the terminal stops bracketing it and the agent reads
        // each pasted line as Enter. The replay goes second on purpose —
        // anything the program changed while nobody was attached is in there,
        // and has to win over what was recorded before it detached.
        //
        // **None of it on this thread.** `ghostty_surface_write_buffer` parses
        // on the caller, and the parser hands surface messages (every title
        // change, every cwd report) to a bounded queue that only the main
        // thread empties, blocking when it's full. A replay from an agent that
        // kept working while detached is exactly that: hundreds of title
        // updates, and the 65th stopped the main thread for good, waiting on
        // itself. So the writes go to the pty's read queue, ahead of the first
        // read, which is the thread the live output has always been parsed on.
        // Only what needs AppKit is read here first.
        let resumed = attachment.resumed
        let replay = attachment.replay
        let dark = Self.systemIsDark
        let status = view.programStatusWatch
        // The agent running there, by its marker: what it switched on at its
        // own startup may never have been recorded (`TerminalModes.assuming`).
        // Only one seen in the process table: a marker outlives its agent
        // until the next command, and focus reports or a theme report sent
        // to the shell it left would be typed at its prompt.
        let agent: String? = resumed ? AgentResumeStore.currentMarker(for: session).flatMap { marker in
            guard case .running = AgentLiveness.locate(agent: marker.agent, shellPID: marker.shellPID,
                                                       table: Self.recentProcessTable()) else { return nil }
            return marker.agent
        } : nil
        // Written down as well as acted on, so a later hibernation's prelude
        // (taken from the record) has them too.
        let prelude = resumed ? TerminalModeRecorder.shared.assume(agent: agent, in: session).prelude : []
        // Whatever the replay asked the terminal was asked long ago, while
        // nobody was attached, and the program is no longer waiting for an
        // answer: one now would arrive as typed input. So the terminal's
        // answers are held back until a marker query written after the replay
        // comes back answered (`ReplayAnswers`). Only for a session that
        // survived: a fresh shell's few bytes were written a moment ago, and
        // whatever it asked it is still waiting on.
        let muteAnswers = resumed && !replay.isEmpty
        pty.enqueue {
            Self.restore(surface: surface, pty: pty, session: session, prelude: prelude,
                         replay: replay, recordReplay: true, muteAnswers: muteAnswers,
                         colorScheme: resumed ? (dark: dark, agent: agent) : nil,
                         status: status)
            // Last, so the shell's prompt and whatever preceded it are on
            // screen before the command appears under them. See `newSurface`.
            if let resumeAgain {
                let bytes = Array(resumeAgain.utf8)
                bytes.withUnsafeBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }
                    pty.write(base, count: raw.count)
                }
            }
        }
        pty.beginReading()
        return surface
    }

    /// Write a session's past into a new terminal: the modes the program
    /// believes in, then what it wrote, then a marker that ends the window in
    /// which the terminal's answers are held back (`ReplayAnswers`), then, if
    /// the program asked to hear about it, what the appearance is now.
    /// A reattach and a wake from hibernation both come back this way.
    ///
    /// **On the pty's queue only**, ahead of any read. See `hostManagedSurface`
    /// for why none of it may run on the main thread.
    static func restore(surface: ghostty_surface_t, pty: PtyHost, session: UUID, prelude: [UInt8],
                        replay: Data, recordReplay: Bool, muteAnswers: Bool,
                        colorScheme: (dark: Bool, agent: String?)?,
                        status: ProgramStatusWatch? = nil) {
        if muteAnswers { pty.muteReplayAnswers() }
        if !prelude.isEmpty {
            prelude.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_write_buffer(surface, base, UInt(raw.count))
            }
        }
        // The buffer holds what the shell wrote while nobody was attached,
        // and it has to reach the terminal before anything newer or the
        // screen ends up out of order.
        if !replay.isEmpty {
            if recordReplay { TerminalModeRecorder.shared.feed(session: session, replay: replay) }
            // What the program last said it was doing, if it said so in here.
            // A fresh shell's few bytes are not a replay: whatever asked a
            // question in them is still waiting for the answer.
            if let status {
                if muteAnswers {
                    status.replay(replay)
                } else {
                    replay.withUnsafeBytes { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        status.output(base, count: raw.count, pty: pty)
                    }
                }
            }
            replay.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_write_buffer(surface, base, UInt(raw.count))
            }
        }
        if muteAnswers {
            // Not after a replay cut off mid-sequence: the marker would
            // cut it short, and the live rest of it would print as text.
            let marked = ReplayAnswers.endsCleanly(replay)
            if marked {
                ReplayAnswers.sentinel.withUnsafeBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }
                    ghostty_surface_write_buffer(surface, base, UInt(raw.count))
                }
            }
            pty.replayWritten(markerSent: marked)
        }

        // And then, if the program asked to hear about it, what the
        // appearance is *now*.
        //
        // Restoring `?2031` above only re-subscribes it; it says nothing
        // about what changed while nobody was attached, and a Mac left on
        // "Auto" flips at sunset. A session resumed the next morning has an
        // agent still painting last night's palette: dark diff blocks on a
        // white screen. It will never notice either, because it asked once,
        // at its own startup, and has been waiting for us ever since.
        //
        // This is the one thing here written to the *program* rather than
        // to the terminal, so it goes after the replay has been read for
        // modes — a program that turned reporting off while detached said
        // so in there, and must not be written to.
        //
        // Sent on every resume, not only when the appearance changed.
        // Tracking what each program was last told would mean persisting a
        // second belief about the far side and being wrong about it
        // silently, which is the shape of the bug this whole file exists
        // for. A report a program already agrees with costs it nothing: it
        // sets the theme it is already painting. The only case that shows
        // is a mode recorded as on for a program that has since exited, and
        // the prelude above already accepts that same risk for seventeen
        // modes with far more to say.
        if let colorScheme,
           TerminalModeRecorder.shared.modes(for: session).assuming(agent: colorScheme.agent).wantsColorSchemeReports {
            let report = TerminalModes.colorSchemeReport(dark: colorScheme.dark)
            report.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                pty.write(base, count: raw.count)
            }
        }
    }

    /// Point a surface config at a pty the app holds: the terminal's bytes
    /// for the program and its size go there instead of to a child of its own.
    private static func hostManaged(_ cfg: inout ghostty_surface_config_s, pty: PtyHost, repaint: Bool) {
        cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        cfg.receive_userdata = Unmanaged.passUnretained(pty).toOpaque()
        // The terminal has bytes for the program: the user typed, or it is
        // answering a query (cursor position, device attributes) on its behalf.
        // Not `write`: during the replay below, those answers are old and are
        // held back (`ReplayAnswers`).
        cfg.receive_buffer = { userdata, bytes, length in
            guard let userdata, let bytes else { return }
            Unmanaged<PtyHost>.fromOpaque(userdata).takeUnretainedValue()
                .writeFromTerminal(bytes, count: length)
        }
        // The grid changed shape. Nobody sends SIGWINCH for us any more — and
        // this is also what corrects the 80x24 the pty was opened at, once
        // the surface has a size to give. Its first report, made before
        // anyone told it one, is libghostty's placeholder and is dropped
        // (`ignoreSizesUntilTold`); `SurfaceView.setSurfaceSize` opens it.
        pty.ignoreSizesUntilTold(repaint: repaint)
        cfg.receive_resize = { userdata, columns, rows, widthPx, heightPx in
            guard let userdata else { return }
            Unmanaged<PtyHost>.fromOpaque(userdata).takeUnretainedValue()
                .resize(columns: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)
        }
    }

    /// Where a keeper session's output goes while it has a terminal: into the
    /// terminal, past the mode recorder. Hibernation swaps it out and back.
    static func liveOutput(surface: ghostty_surface_t, session: UUID,
                           view: SurfaceView) -> (UnsafePointer<UInt8>, Int) -> Void {
        let accessibility = view.accessibilityWatch
        let status = view.programStatusWatch
        // Weak below: the pty holds this closure.
        let pty = view.ptyHost
        return { [weak pty] bytes, count in
            // Watched on the way past, so a relaunch can tell the new terminal
            // what this one has been told. See `TerminalModes`.
            TerminalModeRecorder.shared.feed(session: session, bytes: bytes, count: count)
            // And listened to for what the program says it is doing, which
            // libghostty has no ears for (`ProgramStatusWatch`).
            status.output(bytes, count: count, pty: pty)
            ghostty_surface_write_buffer(surface, bytes, UInt(count))
            // A lock take, and nothing more until a screen reader has asked.
            accessibility.outputArrived()
        }
    }

    /// A new terminal for a hibernated session, around the pty the view still
    /// holds. Nothing is asked of the keeper: the app never stopped reading.
    /// The caller writes the screen back and switches the output to it.
    func wakeSurface(view: SurfaceView, pty: PtyHost, fontSize: Float, repaint: Bool) -> ghostty_surface_t? {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0))
        cfg.font_size = fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // Woken: nothing to repaint. The snapshot is the whole screen, what
        // had scrolled off it included, and it is written back at the size
        // it was taken at with what was missed after it
        // (`SurfaceView.waitForGrid`), so the terminal is as the program
        // left it. Asked to repaint, Claude Code clears it and prints its
        // conversation again, which costs the shell's lines above it and a
        // moment at one column narrow for nothing (it was asked until
        // 2026-11-19, when a woken screen could not be trusted). `repaint`
        // is for the one wake that cannot be trusted still: more was written
        // meanwhile than is kept, so its start is gone.
        Self.hostManaged(&cfg, pty: pty, repaint: repaint)
        return ghostty_surface_new(app, &cfg)
    }

    /// How to start this session's shell — the same shell, with the same
    /// integration, that libghostty's exec backend would have started.
    ///
    /// Everything here is work the exec backend does for us and that owning the
    /// pty takes away. It is not optional dressing: the integration is what
    /// emits OSC 133 command marks, writes the agent marker files, reports the
    /// cwd and puts `wortel` on PATH, so a session without it silently stops
    /// driving busy detection, the attention system and agent resume.
    private static func shellPlan(sessionID: UUID?, environment: [String: String] = [:]) -> ShellSpawn.Plan {
        let resources = Bundle.main.resourceURL
        var extra = environment
        if let sessionID { extra["WORTEL_SESSION_ID"] = sessionID.uuidString }
        if let directory = commandLineToolDirectory { extra["WORTEL_BIN_DIR"] = directory }

        return ShellSpawn.plan(
            shellPath: ShellSpawn.loginShell(),
            resourcesDir: resources?.appendingPathComponent("ghostty").path ?? "",
            terminfoDir: resources?.appendingPathComponent("terminfo").path ?? "",
            // The app's own environment, already scrubbed of whatever launched
            // us (see InheritedEnvironment) — the same baseline libghostty hands
            // a surface, because it inherits from this process too.
            environment: ProcessInfo.processInfo.environment,
            extraEnvironment: extra,
            shellFeatures: ShellSpawn.features(fromConfig: configuredShellFeatures),
            // Where the integration looks for a `ghostty` command, and the only
            // one it runs is `+ssh-cache`. Contents/MacOS holds no such thing,
            // so the check always failed and every `ssh` reinstalled terminfo
            // and left a /tmp directory behind; Resources/ghostty/bin holds a
            // small script that answers it. Not on PATH (the integration takes
            // this directory off PATH), so it isn't a command anyone types.
            binDir: resources?.appendingPathComponent("ghostty/bin").path)
    }

    /// `shell-integration-features` as written in the bundled config, read from
    /// the file rather than copied into Swift so the two cannot drift.
    private static let configuredShellFeatures: String = {
        guard let path = Bundle.main.path(forResource: "wortel", ofType: "conf"),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return "" }
        for line in text.split(separator: "\n") where line.hasPrefix("shell-integration-features") {
            return line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return ""
    }()

    /// The keeper, connected on first use. nil when there is no keeper binary
    /// or it could not be started — the app still runs, it just forks its own
    /// shells and they die with it, exactly as before.
    ///
    /// Replaced only by `reconnectKeeper`, after the one before it died.
    private(set) static var keeper: KeeperConnection? = connectKeeper()

    /// Told when the keeper process ends while the app is running, with its
    /// pid, on the main queue. See `SessionManager.keeperDidExit`.
    static var onKeeperLost: ((pid_t) -> Void)?

    private static func connectKeeper() -> KeeperConnection? {
        guard !PtyHost.isDisabled else {
            NSLog("wortel: keeper disabled; sessions will not survive a quit")
            return nil
        }
        let connection = KeeperConnection()
        guard connection.connect() else {
            NSLog("wortel: no keeper; sessions will not survive a quit")
            return nil
        }
        connection.watchForExit { pid in onKeeperLost?(pid) }
        return connection
    }

    /// Connect to a new keeper, starting one, after the last one died.
    ///
    /// Shells created after this land in the new keeper. Ones the old keeper
    /// held and that are still alive (they can be: the app holds a descriptor
    /// for every terminal it shows) stay with the app and end when it quits.
    @discardableResult
    static func reconnectKeeper() -> KeeperConnection? {
        dispatchPrecondition(condition: .onQueue(.main))
        keeper = connectKeeper()
        return keeper
    }

    /// The process table, read at most once a second.
    ///
    /// For deciding whether a survived shell owes a resume, which runs during
    /// surface creation on the main thread, once for every restored session
    /// that had an agent. Launch warms those one per runloop turn, all within a
    /// second or two, and a whole-table `sysctl` each time is work the launch
    /// doesn't need: an agent that is gone does not come back within a second.
    private static var processTableMemo: (taken: Date, table: [ProcessEntry])?

    static func recentProcessTable() -> [ProcessEntry] {
        dispatchPrecondition(condition: .onQueue(.main))
        if let memo = processTableMemo, Date().timeIntervalSince(memo.taken) < 1 {
            return memo.table
        }
        let table = ProcessTable.snapshot()
        processTableMemo = (Date(), table)
        return table
    }

    /// Where the bundled `wortel` binary lives — `Contents/Resources/bin`,
    /// filled by the CLI target's copy phase. nil in a build without it, which
    /// is why this checks for the binary rather than assuming the directory.
    static var commandLineToolDirectory: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("bin", isDirectory: true)
        let tool = directory.appendingPathComponent("wortel")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? directory.path : nil
    }

    // MARK: - Action dispatch

    private static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Recover the owning runtime from the app handle's userdata (set to
    /// `self` in `init`). Lets the static action callback reach instance state
    /// like the bundled config.
    private static func runtime(fromApp app: ghostty_app_t) -> GhosttyRuntime? {
        guard let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(fromTarget target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Returns true when the action was handled. Returning false for tabs,
    /// splits, inspector, etc. is deliberate: it's Wortel's "those features
    /// don't exist" enforcement.
    private static func handleAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(fromTarget: target),
                  let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr) // copy before returning
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(fromTarget: target),
                  let pwdPtr = action.action.pwd.pwd else { return false }
            let pwd = String(cString: pwdPtr)
            DispatchQueue.main.async { view.reportPwd(pwd) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            guard let view = surfaceView(fromTarget: target) else { return false }
            DispatchQueue.main.async { view.onBell?() }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view = surfaceView(fromTarget: target) else { return false }
            let size = action.action.cell_size
            DispatchQueue.main.async {
                view.cellSizeDidChange(backing: NSSize(width: CGFloat(size.width), height: CGFloat(size.height)))
            }
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            // Only for accessibility: the viewport scrolled, or the history grew
            // under it (the exec backend's only sign of output). Recorded here,
            // on whatever thread this is; the view hears of it throttled.
            guard let view = surfaceView(fromTarget: target) else { return false }
            let scrollbar = action.action.scrollbar
            view.accessibilityWatch.scrolled(total: scrollbar.total, offset: scrollbar.offset)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(fromTarget: target) else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.setCursorShape(shape) }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = surfaceView(fromTarget: target) else { return false }
            let visibility = action.action.mouse_visibility
            DispatchQueue.main.async { view.setCursorVisibility(visibility) }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // libghostty asks the apprt to re-hand it the config. The case that
            // matters for Wortel: when a surface's light/dark color scheme
            // changes, the conditional `theme = light:…,dark:…` must be
            // re-derived, and the core signals that via a *soft* reload here.
            // Wortel is zero-config, so there is nothing to reload from disk —
            // we simply re-apply the single bundled config, which makes the
            // core re-derive conditionals for the surface's current scheme.
            //
            // **Synchronously, before returning**, as Ghostty.app does. This
            // callback runs inside `ghostty_surface_set_color_scheme`, and the
            // very next thing the core does after it returns is send the
            // program its `?997` light/dark report. Claude Code doesn't take
            // that report's word for it: it answers by asking the terminal its
            // background colour (`OSC 11`) and judging light or dark from
            // that. The answer comes from the colours this update installs, so
            // the update has to be queued to the IO thread ahead of the report.
            // Deferred to a later main-queue turn, it lost that race whenever
            // the main thread was busy, and an appearance flip is exactly when
            // it is (every view redraws): the agent asked, heard the old
            // background, and settled on the wrong palette for good. That was
            // the "light diff blocks on a dark screen after sunset" that the
            // reattach fixes in `TerminalModes` could never reach, because it
            // happens to a session that was attached all along.
            //
            // Main-thread only: everything that raises this (a scheme change, a
            // keybind) runs there. Off it, the hop below would bring the race
            // back, so a debug build says so instead of quietly deferring; a
            // release build still hops rather than call into the core from a
            // thread it isn't expecting.
            guard let app, let runtime = runtime(fromApp: app) else { return false }
            let config = runtime.config
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            // The app's own scheme changed: nothing to do, and one thing not
            // to. `ghostty_app_update_config` re-applies the config to every
            // surface *with the scheme that surface still holds*, and each
            // re-apply ends in a `?997` report. Called here, before the
            // surfaces have been told, that report names the old theme, and
            // the program asks for a background that has not changed yet.
            // The surfaces are told one by one right after this
            // (`syncColorScheme`), each with a reload of its own, and a new
            // surface derives its colours from the app's scheme, not from a
            // config the app holds (`Surface.init`, Ghostty 1.3.1), so the
            // app-wide update has nothing left to do. One reload per surface
            // instead of two also halves the times a change of appearance
            // walks into upstream's reload deadlock (#14833, not in 1.3.1).
            // `scripts/try-appearance.sh` checks both: one theme per report,
            // and a session started after a change comes up in the new one.
            if surface == nil, action.action.reload_config.soft { return true }
            let update = {
                if let surface {
                    ghostty_surface_update_config(surface, config)
                } else {
                    ghostty_app_update_config(app, config)
                }
            }
            if Thread.isMainThread {
                update()
            } else {
                assertionFailure("RELOAD_CONFIG off the main thread: the ?997 report will beat the new colours")
                DispatchQueue.main.async(execute: update)
            }
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            // OSC 9;4 (ConEmu). SET / ERROR / INDETERMINATE mean a command is
            // actively working; REMOVE clears it. The bundled shell integration
            // emits an indeterminate report at preexec so this fires for every
            // command, not just tools that report their own progress.
            //
            // PAUSE is *not* working: a program that reports progress and then
            // pauses it is waiting — typically on the user. Treating it as busy
            // left the spinner turning with nothing running, and worse, hid the
            // sidebar status behind it. Same handling as REMOVE, so the quiesce
            // path can raise attention instead.
            guard let view = surfaceView(fromTarget: target) else { return false }
            let state = action.action.progress_report.state
            let active = state != GHOSTTY_PROGRESS_STATE_REMOVE && state != GHOSTTY_PROGRESS_STATE_PAUSE
            // ERROR is still working, but the program has said the work is
            // failing: when the span then ends, it ended badly.
            let errored = state == GHOSTTY_PROGRESS_STATE_ERROR
            // Gated like the title trace: a program reporting real progress can
            // emit these many times a second, and this runs on libghostty's
            // thread.
            if AgentStatusLog.isTracing {
                AgentStatusLog.log.debug(
                    "progress state=\(state.rawValue, privacy: .public) → busy=\(active, privacy: .public)")
            }
            DispatchQueue.main.async { view.onProgress?(active, errored) }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // OSC 133;D. Authoritative "back at a prompt" — fires at every
            // command boundary, so the busy state can never get stuck.
            guard let view = surfaceView(fromTarget: target) else { return false }
            let finished = action.action.command_finished
            let exitCode = Int(finished.exit_code)
            let durationNs = finished.duration
            DispatchQueue.main.async { view.onCommandFinished?(exitCode, durationNs) }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view = surfaceView(fromTarget: target) else { return false }
            let note = action.action.desktop_notification
            let title = note.title.map { String(cString: $0) } ?? ""
            let body = note.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                // Only for a terminal whose pty libghostty owns (no keeper).
                // Everywhere else Wortel has read the notification off the
                // output itself (`ProgramStatusWatch`), and this arrival is
                // the same one again, after the core's one-a-second limit for
                // the whole app has dropped some.
                guard view.ptyHost == nil else { return }
                view.onNotification?(title, body, false)
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // A ⌘-clicked link: a URL, an OSC 8 hyperlink, or a matched path.
            // Two kinds are ours. A path (or a `file:` URL): only the app knows
            // what a relative one is relative to, and libghostty's own open
            // runs from the app's working directory, `/`, where `docs/x.md` is
            // nothing. And a server on this Mac, which opens beside the
            // terminal unless servers go to the browser. Both are taken here
            // and handled on the main actor (`TerminalLink`). Other web links,
            // mailto: and other schemes return false, and libghostty opens
            // them itself (web links land in the system browser). The test is
            // pure string work because its answer is this return value.
            guard let view = surfaceView(fromTarget: target) else { return false }
            let open = action.action.open_url
            guard let ptr = open.url else { return false }
            // The bytes aren't guaranteed NUL-terminated; `len` is authoritative.
            let link = String(decoding: Data(bytes: ptr, count: Int(open.len)), as: UTF8.self)
            guard TerminalLink.isPath(link) || TerminalLink.localServer(link) != nil else { return false }
            DispatchQueue.main.async { view.onOpenLink?(link) }
            return true

        default:
            // Tabs, splits, inspector, command palette, search UI, etc.
            return false
        }
    }
}
