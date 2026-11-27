#if DEBUG
import AppKit
import GhosttyKit

/// Switch between sessions the way a hand does, quickly and back, and write
/// down where the terminal ended up each time.
///
/// For the fault where a terminal comes back drawn as wide as its page is
/// without the side column, running under the column and cut off by it
/// (2026-11-18, and again 2026-11-19 in a recording). It shows only after
/// some switches and not others, so it wants many, at several paces, and a
/// record of what the terminal was told against where its view is.
///
/// Debug builds only, and only a copy with a data folder of its own
/// (`WORTEL_DATA_DIR`): it switches sessions, opens the column, and for
/// `pages` closes every session. Addressed by pid; the object is the file to
/// write:
///
///     "sh.wortel.test.switch.<pid>", "/tmp/switch.json"
///
/// The session in front is the one measured. Its side column is opened if it
/// is shut; the others are left as they are. `scripts/try-switch.sh` wraps it.
enum SwitchProbe {
    private static var observer: NSObjectProtocol?
    private static var running = false

    static func install(manager: SessionManager, git: GitPanelModel) {
        let name = Notification.Name("sh.wortel.test.switch.\(ProcessInfo.processInfo.processIdentifier)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak manager, weak git] note in
            guard let request = note.object as? String, let manager, let git else { return }
            MainActor.assumeIsolated { Task { @MainActor in await run(manager, git, request: request) } }
        }
    }

    @MainActor
    private static func run(_ manager: SessionManager, _ git: GitPanelModel, request: String) async {
        guard !running, let home = manager.selected else { return }
        running = true
        defer { running = false }
        let parts = request.split(separator: "|").map(String.init)
        guard let path = parts.first else { return }
        // Whatever a round sets, the copy is left on Wortel's own rule.
        defer { if SurfaceView.frameOnEveryResize { SurfaceView.frameOnEveryResize = false } }
        // "report": where the terminal in front is now, and who has the
        // keyboard, with nothing switched.
        // "column": open the side column of the session in front, and no more.
        if parts.contains("column") && !parts.contains("side") && !parts.contains("widths") {
            if state(of: home).columnShut {
                NSApp.sendAction(#selector(AppDelegate.toggleSideColumn(_:)), to: nil, from: nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            try? Data(#"{"column":"open"}"#.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        if parts.contains("report") {
            var report = state(of: home).json
            // Every SwiftUI hosting view in the window, where it is and the
            // safe area it is given: one with none to keep clear of can stop
            // following it (`safeAreaRegions = []`) and nothing moves.
            var hosts: [String] = []
            func visit(_ view: NSView) {
                let name = String(describing: type(of: view))
                if name.contains("NSHostingView") || name.contains("PagesView") {
                    let insets = view.safeAreaInsets
                    let frame = view.convert(view.bounds, to: nil)
                    hosts.append("\(name.prefix(44)) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                        + " insets t\(Int(insets.top)) l\(Int(insets.left)) b\(Int(insets.bottom)) r\(Int(insets.right))"
                        + (view.isHiddenOrHasHiddenAncestor ? " hidden" : ""))
                }
                view.subviews.forEach(visit)
            }
            home.surfaceView?.window?.contentView.map(visit)
            report["hosts"] = hosts
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        // "pages": what a click in the terminal's pane lands on, with a
        // session and then with none, when the page for that is up.
        if parts.contains("pages") {
            await pages(manager, home: home, path: path)
            return
        }
        let before = parts.contains("before")
        if SurfaceView.frameOnEveryResize != before { SurfaceView.frameOnEveryResize = before }
        let others = manager.sessions.filter { $0.id != home.id }
        guard !others.isEmpty else { return }

        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        if state(of: home).columnShut {
            NSApp.sendAction(#selector(AppDelegate.toggleSideColumn(_:)), to: nil, from: nil)
            await pause(1)
        }
        // "side": a terminal of its own in the column, measured as well.
        if parts.contains("side"), home.sideSurfaces.isEmpty {
            git.openTerminal()
            await pause(1.5)
        }
        // "widths": the first other session gets a column too, 120 points
        // wider, so a switch between the two moves the divider.
        if parts.contains("widths") {
            // A width of its own for this one first, or it takes the last
            // width any session was dragged to and the two end up the same.
            if let terminal = home.surfaceView { dragSide(beside: terminal, wider: -40) }
            await pause(0.8)
            manager.select(id: others[0].id)
            await pause(0.6)
            if state(of: others[0]).columnShut {
                NSApp.sendAction(#selector(AppDelegate.toggleSideColumn(_:)), to: nil, from: nil)
                await pause(1)
            }
            if let terminal = others[0].surfaceView { dragSide(beside: terminal, wider: 120) }
            await pause(0.8)
            manager.select(id: home.id)
            await pause(0.8)
        }

        // Where the terminal is before anything moves, with the column and,
        // on another session, without it: what every return is held to.
        let start = state(of: home)
        manager.select(id: others[0].id)
        await pause(0.8)
        let startOther = state(of: others[0])
        manager.select(id: home.id)
        await pause(0.8)

        var rows: [[String: Any]] = []
        // Away for `gap`, through `stops` other sessions, and back.
        for gap in [0.4, 0.2, 0.1, 0.05, 0.02, 0.0] {
            for stops in 1...min(3, others.count) {
                for _ in 0..<4 {
                    for other in others.prefix(stops) {
                        manager.select(id: other.id)
                        if gap > 0 { await pause(gap) }
                    }
                    manager.select(id: home.id)
                    // What a glance sees, and what is still true a moment on.
                    await pause(0.15)
                    let soon = state(of: home)
                    await pause(0.6)
                    let settled = state(of: home)
                    rows.append(["gap": gap, "stops": stops, "soon": soon.json, "settled": settled.json])
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["mode": before ? "before" : "now", "rows": rows,
                                                                   "start": start.json, "startOther": startOther.json],
                                                  options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    struct State {
        var columnShut = true
        /// How far the terminal's view runs under the pane beside it, in points.
        var under: CGFloat = 0
        var viewPx: (Int, Int) = (0, 0)
        var surface: SurfaceView.DebugState?
        var chain: [String] = []
        /// In the window, in points.
        var frame = ""
        /// What takes the keys, and whether its window is the key one.
        var responder = ""
        var keyWindow = false
        /// What a click in the middle of the terminal lands on.
        var hit = ""
        /// The session's terminal in the side column, if one is in front
        /// there: where it is, the pane it should fill, and what it was told.
        var side: [String: Any]?

        var json: [String: Any] {
            var out: [String: Any] = ["columnShut": columnShut, "under": Double(under),
                                      "view": "\(viewPx.0)x\(viewPx.1)", "chain": chain, "frame": frame,
                                      "responder": responder, "keyWindow": keyWindow, "hit": hit]
            if let side { out["side"] = side }
            if let surface {
                out["told"] = surface.told.map { "\($0.0)x\($0.1)" } ?? "nothing"
                out["grid"] = "\(surface.columns)x\(surface.rows)"
                out["gridFits"] = surface.gridWidthPx <= viewPx.0
                out["shown"] = surface.shown.map { "\($0.0)x\($0.1)" } ?? "nothing"
                out["layer"] = "\(surface.layerPx.0)x\(surface.layerPx.1)"
                out["pending"] = surface.pending
                out["holds"] = surface.holds
                out["hidden"] = surface.hidden
            }
            return out
        }
    }

    @MainActor
    private static func state(of session: Session) -> State {
        var state = State()
        guard let terminal = session.surfaceView, let window = terminal.window else { return state }
        let frame = terminal.convert(terminal.bounds, to: nil)
        let backing = terminal.convertToBacking(terminal.bounds.size)
        state.viewPx = (Int(backing.width), Int(backing.height))
        state.frame = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        state.surface = terminal.debugState
        state.responder = window.firstResponder === terminal
            ? "this terminal" : window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
        state.keyWindow = window.isKeyWindow
        state.hit = hit(at: NSPoint(x: frame.midX, y: frame.midY), in: window, terminal: terminal)
        // The side split, from the window's tree of splits: how far the
        // terminal's view runs under it.
        if let tree = tree(above: terminal), let leaf = tree.frame(of: .side) {
            let sideFrame = tree.convert(leaf, to: nil)
            state.columnShut = false
            state.under = sideFrame.midX > frame.midX ? frame.maxX - sideFrame.minX : sideFrame.maxX - frame.minX
            state.chain = tree.visibleLeaves.map { entry in
                let rect = tree.convert(entry.frame, to: nil)
                return "\(entry.leaf.rawValue.prefix(8)) \(Int(rect.minX)),\(Int(rect.width))"
            }
        }
        if let side = session.sideSurfaces.values.first(where: { !$0.isHidden && $0.window != nil }) {
            let sideFrame = side.convert(side.bounds, to: nil)
            let px = side.convertToBacking(side.bounds.size)
            let debug = side.debugState
            var out: [String: Any] = [
                "frame": "\(Int(sideFrame.minX)),\(Int(sideFrame.minY)) \(Int(sideFrame.width))x\(Int(sideFrame.height))",
                "view": "\(Int(px.width))x\(Int(px.height))",
                "told": debug.told.map { "\($0.0)x\($0.1)" } ?? "nothing",
                "grid": "\(debug.columns)x\(debug.rows)",
                "shown": debug.shown.map { "\($0.0)x\($0.1)" } ?? "nothing",
                "layer": "\(debug.layerPx.0)x\(debug.layerPx.1)",
            ]
            // The split it is in: the side split's leaf of the window's tree.
            if let tree = tree(above: side), let leaf = tree.frame(of: .side) {
                let pane = tree.convert(leaf, to: nil)
                out["pane"] = "\(Int(pane.minX)),\(Int(pane.width))"
                out["inPane"] = sideFrame.minX >= pane.minX - 0.5 && sideFrame.maxX <= pane.maxX + 0.5
                    && abs(sideFrame.width - pane.width) < 1.5
            }
            state.side = out
        }
        return state
    }

    /// The view a click at a point in the window lands on, by name.
    @MainActor
    private static func hit(at point: NSPoint, in window: NSWindow, terminal: SurfaceView?) -> String {
        guard let found = window.contentView?.superview?.hitTest(point) else { return "nothing" }
        if found === terminal { return "this terminal" }
        var chain: [String] = []
        var up: NSView? = found
        while let current = up, chain.count < 3 {
            chain.append(String(String(describing: type(of: current)).prefix(40)))
            up = current.superview
        }
        return chain.joined(separator: " < ")
    }

    @MainActor
    private static func pages(_ manager: SessionManager, home: Session, path: String) async {
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        guard let terminal = home.surfaceView, let window = terminal.window else { return }
        let frame = terminal.convert(terminal.bounds, to: nil)
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        var result: [String: Any] = ["withSession": hit(at: middle, in: window, terminal: terminal)]
        for session in manager.sessions { manager.close(session) }
        await pause(1)
        result["sessionsLeft"] = manager.sessions.count
        result["withNone"] = hit(at: middle, in: window, terminal: nil)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The window's tree of splits, found from a terminal in it.
    @MainActor
    private static func tree(above view: NSView) -> SplitTreeView? {
        var up: NSView? = view
        while let current = up {
            if let tree = current as? SplitTreeView { return tree }
            up = current.superview
        }
        return nil
    }

    /// Drag the divider beside the side split so the split is `wider` points
    /// wider (narrower when negative), as a hand on it would.
    @MainActor
    private static func dragSide(beside terminal: SurfaceView, wider: CGFloat) {
        guard let tree = tree(above: terminal), let side = tree.frame(of: .side) else { return }
        // The divider on the side split's inner edge, whichever side it is on.
        let dividers = tree.dividerRects
        guard let index = dividers.firstIndex(where: {
            abs($0.maxX - side.minX) < 1.5 || abs($0.minX - side.maxX) < 1.5
        }) else { return }
        let onRight = abs(dividers[index].maxX - side.minX) < 1.5
        tree.dragDivider(index, by: onRight ? -wider : wider)
    }
}
#endif
