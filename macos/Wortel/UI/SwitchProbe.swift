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
/// Debug builds only, addressed by pid; the object is the file to write:
///
///     "sh.wortel.test.switch.<pid>", "/tmp/switch.json"
///
/// The session in front is the one measured. Its side column is opened if it
/// is shut; the others are left as they are. `scripts/try-switch.sh` wraps it.
enum SwitchProbe {
    private static var observer: NSObjectProtocol?
    private static var running = false

    static func install(manager: SessionManager) {
        let name = Notification.Name("sh.wortel.test.switch.\(ProcessInfo.processInfo.processIdentifier)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak manager] note in
            guard let request = note.object as? String, let manager else { return }
            MainActor.assumeIsolated { Task { @MainActor in await run(manager, request: request) } }
        }
    }

    @MainActor
    private static func run(_ manager: SessionManager, request: String) async {
        guard !running, let home = manager.selected else { return }
        running = true
        defer { running = false }
        let parts = request.split(separator: "|").map(String.init)
        let path = parts[0]
        // "report": where the terminal in front is now, and who has the
        // keyboard, with nothing switched.
        if parts.contains("report") {
            if let data = try? JSONSerialization.data(withJSONObject: state(of: home).json, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
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

        var json: [String: Any] {
            var out: [String: Any] = ["columnShut": columnShut, "under": Double(under),
                                      "view": "\(viewPx.0)x\(viewPx.1)", "chain": chain, "frame": frame,
                                      "responder": responder, "keyWindow": keyWindow]
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
        return state
    }
}
#endif
