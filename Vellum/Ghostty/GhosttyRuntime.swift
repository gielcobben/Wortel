import AppKit
import GhosttyKit

/// Owns the libghostty process state: ghostty_init, the config, the app
/// handle, tick scheduling, and the runtime callbacks.
///
/// Threading: libghostty may invoke callbacks from its IO/render threads.
/// Callbacks copy any C-pointer data synchronously, then hop to the main
/// thread for anything that touches AppKit. Everything Vellum owns runs on
/// the main thread.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!
    private let config: ghostty_config_t
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    /// argv passed to ghostty_init. Ghostty stores these pointers process-wide
    /// (std.os.argv), so they must stay alive for the process lifetime.
    private static var argvStorage: [UnsafeMutablePointer<CChar>?] = []

    init?() {
        // -- ghostty_init with synthetic argv ---------------------------------
        Self.argvStorage = GhosttyConfig.defaults.map { strdup($0) }
        guard ghostty_init(UInt(Self.argvStorage.count), &Self.argvStorage) == GHOSTTY_SUCCESS else {
            return nil
        }

        // -- Config: CLI args only, never the user's config files -------------
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_cli_args(config)
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
                  let surface = view.surface,
                  let string = NSPasteboard.general.string(forType: .string)
            else { return false }
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, string, state, _ in
            // Personal machine: auto-approve paste-protection requests.
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
    func newSurface(view: SurfaceView, workingDirectory: String? = nil, fontSize: Float = 0) -> ghostty_surface_t? {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0))
        cfg.font_size = fontSize
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        if let workingDirectory {
            return workingDirectory.withCString { cwdPtr in
                cfg.working_directory = cwdPtr
                return ghostty_surface_new(app, &cfg)
            }
        }
        return ghostty_surface_new(app, &cfg)
    }

    // MARK: - Action dispatch

    private static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(fromTarget target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Returns true when the action was handled. Returning false for tabs,
    /// splits, inspector, etc. is deliberate: it's Vellum's "those features
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

        default:
            // Tabs, splits, inspector, command palette, search UI, etc.
            return false
        }
    }
}
