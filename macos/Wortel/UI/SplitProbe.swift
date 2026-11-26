#if DEBUG
import AppKit

/// Split the main area the way a hand does, one command after another, and
/// write down where everything ended up: each split's frame and tabs, where
/// each terminal's view is against the split it belongs to, what the terminal
/// was told, and who has the keyboard.
///
/// For checking splits without touching the screen: the things that go wrong
/// with them (a terminal left at the size it had before the split, a view
/// running under its neighbour, the keyboard in a terminal that is out of
/// sight) are all in those numbers.
///
/// Debug builds only, and only a copy with a data folder of its own
/// (`WORTEL_DATA_DIR`): it opens and closes terminals. Addressed by pid; the
/// object is the file to write, then the steps, each separated by `|`:
///
///     "sh.wortel.test.split.<pid>", "/tmp/splits.json|right|down|zoom|zoom"
///
/// Steps: `right` `down` `left` `up` (a new terminal in a split on that edge
/// of the area you're in), `focus-left` `focus-right` `focus-up`
/// `focus-down`, `move-left` `move-right` `move-up` `move-down` (the tab in
/// front), `zoom`, `equalize`, `tab` (a terminal tab here), `close` (the tab
/// in front here), `column`, `strip`, `next` (the next session), `wide`
/// (drag the first divider 80 points), and `picture:<path>` (the window as
/// its views draw themselves, to a PNG; terminals are drawn by the GPU and
/// come out as their page colour). `scripts/try-splits.sh` wraps it.
enum SplitProbe {
    private static var observer: NSObjectProtocol?
    private static var running = false

    static func install(manager: SessionManager, controller: MainWindowController) {
        let name = Notification.Name("sh.wortel.test.split.\(ProcessInfo.processInfo.processIdentifier)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak manager, weak controller] note in
            guard let request = note.object as? String, let manager, let controller else { return }
            MainActor.assumeIsolated { Task { @MainActor in await run(manager, controller, request: request) } }
        }
    }

    @MainActor
    private static func run(_ manager: SessionManager, _ controller: MainWindowController,
                            request: String) async {
        guard !running else { return }
        running = true
        defer { running = false }
        var steps = request.split(separator: "|").map(String.init)
        guard !steps.isEmpty else { return }
        let path = steps.removeFirst()
        let git = controller.gitPanel
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

        var trail: [[String: Any]] = []
        for step in steps {
            switch step {
            case "right": send(#selector(AppDelegate.splitRight(_:)))
            case "down": send(#selector(AppDelegate.splitDown(_:)))
            case "left": git.split(on: .left)
            case "up": git.split(on: .up)
            case "focus-left": send(#selector(AppDelegate.focusSplitLeft(_:)))
            case "focus-right": send(#selector(AppDelegate.focusSplitRight(_:)))
            case "focus-up": send(#selector(AppDelegate.focusSplitUp(_:)))
            case "focus-down": send(#selector(AppDelegate.focusSplitDown(_:)))
            case "move-left": send(#selector(AppDelegate.moveTabLeft(_:)))
            case "move-right": send(#selector(AppDelegate.moveTabRight(_:)))
            case "move-up": send(#selector(AppDelegate.moveTabUp(_:)))
            case "move-down": send(#selector(AppDelegate.moveTabDown(_:)))
            case "zoom": send(#selector(AppDelegate.zoomSplit(_:)))
            case "equalize": send(#selector(AppDelegate.equalizeSplits(_:)))
            case "tab": send(#selector(AppDelegate.newTerminalHere(_:)))
            case "close": send(#selector(AppDelegate.closeSession(_:)))
            case "column": send(#selector(AppDelegate.toggleSideColumn(_:)))
            case "strip": send(#selector(AppDelegate.toggleBottomStrip(_:)))
            case "next": send(#selector(AppDelegate.selectNextSession(_:)))
            case "wide":
                treeView(in: controller)?.dragDivider(0, by: 80)
            case let picture where picture.hasPrefix("picture:"):
                await pause(0.4)
                draw(controller.window, to: String(picture.dropFirst("picture:".count)))
                continue
            default:
                trail.append(["step": step, "unknown": true])
                continue
            }
            // Long enough for a new terminal to be made, laid out and told
            // its size, and for a held resize to be let go.
            await pause(1.2)
            var entry = state(manager, controller)
            entry["step"] = step
            trail.append(entry)
        }
        var report = state(manager, controller)
        report["trail"] = trail
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    private static func treeView(in controller: MainWindowController) -> SplitTreeView? {
        controller.split.mainArea?.view as? SplitTreeView
    }

    @MainActor
    private static func state(_ manager: SessionManager, _ controller: MainWindowController) -> [String: Any] {
        let git = controller.gitPanel
        let window = controller.window
        func text(_ rect: NSRect) -> String {
            "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
        }
        var out: [String: Any] = [
            "isSplit": git.splitLayout.isSplit,
            "zoomed": git.zoomedRegion?.rawValue ?? "",
            "area": git.lastRegion.rawValue,
            "keyWindow": window.isKeyWindow,
        ]
        let frames = controller.split.mainArea?.paneFrames ?? []
        out["splits"] = frames.map { entry -> [String: Any] in
            ["region": entry.region.rawValue, "frame": text(entry.frame),
             "tabs": git.tabs(in: entry.region).map(\.rawValue),
             "front": git.activeTab(in: entry.region)?.rawValue ?? ""]
        }
        guard let session = manager.selected else { return out }
        // Every terminal of the session that is in the window and not hidden:
        // where its view is, the split it should be inside, and what it was told.
        var terminals: [[String: Any]] = []
        var surfaces: [(String, SurfaceView)] = []
        if let main = session.surfaceView { surfaces.append(("session", main)) }
        for (id, surface) in session.sideSurfaces { surfaces.append((SideTab.terminal(id).rawValue, surface)) }
        for (name, surface) in surfaces where surface.window != nil {
            let frame = surface.convert(surface.bounds, to: nil)
            let px = surface.convertToBacking(surface.bounds.size)
            let debug = surface.debugState
            let tab = SideTab(rawValue: name) ?? .session
            let region = session.workspace.region(of: tab)
            var entry: [String: Any] = [
                "tab": name, "region": region?.rawValue ?? "", "frame": text(frame),
                "view": "\(Int(px.width))x\(Int(px.height))",
                "told": debug.told.map { "\($0.0)x\($0.1)" } ?? "nothing",
                "grid": "\(debug.columns)x\(debug.rows)",
                "gridFits": debug.gridWidthPx <= Int(px.width),
                "hidden": surface.isHiddenOrHasHiddenAncestor,
                "holds": debug.holds,
                "keyboard": window.firstResponder === surface,
            ]
            if let region, let pane = frames.first(where: { $0.region == region }) {
                // Inside its split, to the point: a view that runs past it is
                // drawn under its neighbour.
                entry["inside"] = pane.frame.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            }
            terminals.append(entry)
        }
        out["terminals"] = terminals.sorted { ($0["tab"] as? String ?? "") < ($1["tab"] as? String ?? "") }
        if let responder = window.firstResponder as? NSView {
            out["keyboardIn"] = controller.split.mainArea?.region(containing: responder)?.rawValue
                ?? String(describing: type(of: responder))
        }
        return out
    }

    /// The window as its views draw themselves, without the screen.
    @MainActor
    private static func draw(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
