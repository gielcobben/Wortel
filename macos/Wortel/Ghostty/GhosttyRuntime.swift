import AppKit
import GhosttyKit

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
    private var appearanceObservation: NSKeyValueObservation?

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

        // -- System appearance forwarding (app-level) --------------------------
        let applyAppearance = { (appearance: NSAppearance) in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ghostty_app_set_color_scheme(
                appHandle, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }
        applyAppearance(NSApp.effectiveAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { app, _ in
            applyAppearance(app.effectiveAppearance)
        }

        // Prime the mailbox once.
        ghostty_app_tick(appHandle)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        ghostty_app_free(app)
        ghostty_config_free(config)
    }

    // MARK: - Surface creation

    /// Create a new surface attached to `view`. The view is the surface
    /// userdata for all callbacks.
    func newSurface(view: SurfaceView, workingDirectory: String? = nil,
                    sessionID: UUID? = nil, initialInput: String? = nil,
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

        // The process-survival spike, opt-in via WORTEL_HOST_MANAGED=1. See
        // PtyHost: we own the pty, libghostty is only the emulator. Everything
        // above that describes a *process* — working_directory, initial_input,
        // env_vars — has nothing to act on in this mode, which is exactly the
        // cost the spike is here to measure.
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
        if let sessionID, let keeper = Self.keeper,
           let attachment = keeper.attachOrOpen(
               session: sessionID, plan: Self.shellPlan(sessionID: sessionID),
               workingDirectory: workingDirectory, columns: 80, rows: 24) {
            // A session that never died has nothing to resume; see below.
            if attachment.resumed { cfg.initial_input = nil }
            return hostManagedSurface(view: view, config: &cfg, attachment: attachment)
        }

        return envVars.withUnsafeMutableBufferPointer { buf in
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
        attachment: KeeperConnection.Attachment
    ) -> ghostty_surface_t? {
        let pty = PtyHost(adopting: attachment.descriptor)
        view.ptyHost = pty // the view's lifetime is the session's
        view.keeperSession = attachment.session

        cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        cfg.receive_userdata = Unmanaged.passUnretained(pty).toOpaque()
        // The terminal has bytes for the program: the user typed, or it is
        // answering a query (cursor position, device attributes) on its behalf.
        cfg.receive_buffer = { userdata, bytes, length in
            guard let userdata, let bytes else { return }
            Unmanaged<PtyHost>.fromOpaque(userdata).takeUnretainedValue()
                .write(bytes, count: length)
        }
        // The grid changed shape. Nobody sends SIGWINCH for us any more — and
        // this is also what corrects the 80x24 the pty was opened at, since the
        // surface had no size to give until now.
        cfg.receive_resize = { userdata, columns, rows, widthPx, heightPx in
            guard let userdata else { return }
            Unmanaged<PtyHost>.fromOpaque(userdata).takeUnretainedValue()
                .resize(columns: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)
        }

        guard let surface = ghostty_surface_new(app, &cfg) else {
            NSLog("wortel: host-managed surface could not be created")
            return nil
        }

        pty.onOutput = { bytes, count in
            ghostty_surface_write_buffer(surface, bytes, UInt(count))
        }
        pty.onExit = { code, milliseconds in
            DispatchQueue.main.async {
                ghostty_surface_process_exit(surface, UInt32(bitPattern: code), milliseconds)
            }
        }

        // Replay first, then read: the buffer holds what the shell wrote while
        // nobody was attached, and it has to reach the terminal before anything
        // newer or the screen ends up out of order.
        if !attachment.replay.isEmpty {
            attachment.replay.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_write_buffer(surface, base, UInt(raw.count))
            }
        }
        pty.beginReading()
        return surface
    }

    /// How to start this session's shell — the same shell, with the same
    /// integration, that libghostty's exec backend would have started.
    ///
    /// Everything here is work the exec backend does for us and that owning the
    /// pty takes away. It is not optional dressing: the integration is what
    /// emits OSC 133 command marks, writes the agent marker files, reports the
    /// cwd and puts `wortel` on PATH, so a session without it silently stops
    /// driving busy detection, the attention system and agent resume.
    private static func shellPlan(sessionID: UUID?) -> ShellSpawn.Plan {
        let resources = Bundle.main.resourceURL
        var extra: [String: String] = [:]
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
            binDir: Bundle.main.executableURL?.deletingLastPathComponent().path)
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

    /// The keeper, connected once per launch. nil when there is no keeper
    /// binary or it could not be started — the app still runs, it just forks its
    /// own shells and they die with it, exactly as before.
    static let keeper: KeeperConnection? = {
        guard !PtyHost.isDisabled else {
            NSLog("wortel: keeper disabled; sessions will not survive a quit")
            return nil
        }
        let connection = KeeperConnection()
        guard connection.connect() else {
            NSLog("wortel: no keeper; sessions will not survive a quit")
            return nil
        }
        return connection
    }()

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
            DispatchQueue.main.async { view.onPwdChange?(pwd) }
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
            guard let app, let runtime = runtime(fromApp: app) else { return false }
            let config = runtime.config
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                DispatchQueue.main.async { ghostty_surface_update_config(surface, config) }
            } else {
                DispatchQueue.main.async { ghostty_app_update_config(app, config) }
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
            // Gated like the title trace: a program reporting real progress can
            // emit these many times a second, and this runs on libghostty's
            // thread.
            if AgentStatusLog.isTracing {
                AgentStatusLog.log.debug(
                    "progress state=\(state.rawValue, privacy: .public) → busy=\(active, privacy: .public)")
            }
            DispatchQueue.main.async { view.onProgress?(active) }
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
            DispatchQueue.main.async { view.onNotification?(title, body) }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // A ⌘-clicked link — a URL, an OSC 8 hyperlink, or a matched path. We
            // intercept one kind: a local markdown file (→ the in-app preview).
            // Everything else — web links, other files, mailto:, custom schemes —
            // returns false so libghostty performs its own default open (web
            // links land in the system browser). The decision is synchronous and
            // cwd-free (see MarkdownLink) because the return value gates
            // libghostty right here — we can't defer to the main actor and still
            // answer "did you handle it?". So Wortel never becomes the thing
            // that launches an arbitrary file on a single click.
            guard let view = surfaceView(fromTarget: target) else { return false }
            let open = action.action.open_url
            guard let ptr = open.url else { return false }
            // The bytes aren't guaranteed NUL-terminated; `len` is authoritative.
            let link = String(decoding: Data(bytes: ptr, count: Int(open.len)), as: UTF8.self)
            if let fileURL = MarkdownLink.fileURL(from: link) {
                DispatchQueue.main.async { view.onOpenMarkdown?(fileURL) }
                return true
            }
            return false

        default:
            // Tabs, splits, inspector, command palette, search UI, etc.
            return false
        }
    }
}
