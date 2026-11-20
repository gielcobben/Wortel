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
            if let terminal = home.surfaceView, let split = columnDivider(beside: terminal) {
                let edge = split.view.arrangedSubviews[split.divider].frame.maxX
                split.view.setPosition(edge + 40 * split.towardsTerminal, ofDividerAt: split.divider)
                await pause(0.8)
            }
            manager.select(id: others[0].id)
            await pause(0.6)
            if state(of: others[0]).columnShut {
                NSApp.sendAction(#selector(AppDelegate.toggleSideColumn(_:)), to: nil, from: nil)
                await pause(1)
            }
            if let terminal = others[0].surfaceView, let split = columnDivider(beside: terminal) {
                let edge = split.view.arrangedSubviews[split.divider].frame.maxX
                split.view.setPosition(edge - 120 * split.towardsTerminal, ofDividerAt: split.divider)
                await pause(0.8)
            }
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
        // The pane after the terminal's in the main split view.
        var view: NSView? = terminal
        while let current = view {
            if let split = current.superview as? NSSplitView, split.isVertical,
               split.delegate is MainSplitViewController,
               let index = split.arrangedSubviews.firstIndex(of: current) {
                let panes = split.arrangedSubviews
                for beside in [index + 1, index - 1] where panes.indices.contains(beside) && beside != 0 {
                    let pane = panes[beside]
                    guard !split.isSubviewCollapsed(pane), pane.frame.width > 1 else { continue }
                    state.columnShut = false
                    let paneFrame = pane.convert(pane.bounds, to: nil)
                    state.under = beside > index ? frame.maxX - paneFrame.minX : paneFrame.maxX - frame.minX
                    // Which view is the wide one: every ancestor up to the pane.
                    var chain: [String] = []
                    var up: NSView? = terminal
                    while let v = up, v !== split {
                        chain.append("\(String(describing: type(of: v)).prefix(28)) \(Int(v.frame.minX)),\(Int(v.frame.width))")
                        up = v.superview
                    }
                    chain.append("panes " + panes.map { "\(Int($0.frame.minX)),\(Int($0.frame.width))" }.joined(separator: " | "))
                    state.chain = chain
                }
                break
            }
            view = current.superview
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
            // The pane it is in: the main split view's, found from the terminal up.
            var up: NSView? = side
            while let current = up {
                if let split = current.superview as? NSSplitView, split.isVertical,
                   split.delegate is MainSplitViewController {
                    let pane = current.convert(current.bounds, to: nil)
                    out["pane"] = "\(Int(pane.minX)),\(Int(pane.width))"
                    out["inPane"] = sideFrame.minX >= pane.minX - 0.5 && sideFrame.maxX <= pane.maxX + 0.5
                        && abs(sideFrame.width - pane.width) < 1.5
                    break
                }
                up = current.superview
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

    /// The main split view and the divider between the terminal's pane and
    /// an open pane beside it that is not the sidebar.
    @MainActor
    private static func columnDivider(
        beside terminal: SurfaceView
    ) -> (view: NSSplitView, divider: Int, towardsTerminal: CGFloat)? {
        var view: NSView? = terminal
        while let current = view {
            if let split = current.superview as? NSSplitView, split.isVertical,
               split.delegate is MainSplitViewController,
               let index = split.arrangedSubviews.firstIndex(of: current) {
                let panes = split.arrangedSubviews
                func open(_ i: Int) -> Bool {
                    panes.indices.contains(i) && !split.isSubviewCollapsed(panes[i]) && panes[i].frame.width > 1
                }
                if open(index + 1) { return (split, index, 1) }
                if index - 1 > 0, open(index - 1) { return (split, index - 1, -1) }
                return nil
            }
            view = current.superview
        }
        return nil
    }
}
#endif
