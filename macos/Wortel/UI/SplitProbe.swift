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
/// in front here), `select:<n>` (the nth tab of the row you're in to the
/// front), `trace-tab` `trace-blank` `trace-close` (a tab added or closed,
/// with the row's motion sampled every 20ms), `column`, `strip`, `sidebar`
/// (hide or show it), `next` (the next session), `wide`
/// (drag the first divider 80 points), `resize:<w>x<h>` (the window to that
/// size in points, in twenty steps), `light` and `dark` (the copy's
/// appearance, for a picture), `drop:<n>.<where>` (the tab in front
/// of the area you're in, let go on split number `n` in reading order, at
/// its `left`, `right`, `up` or `down` edge or its `middle`), and
/// `picture:<path>` (the window as
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
            case "reset": send(#selector(AppDelegate.resetLayout(_:)))
            case "tab": send(#selector(AppDelegate.newTerminalHere(_:)))
            // The "+" of the row you're in, the split buttons, and a pick
            // on the empty tab's page.
            case "blank": git.openBlank(in: git.lastRegion)
            case "blank-right": send(#selector(AppDelegate.newSplitRight(_:)))
            case "blank-down": send(#selector(AppDelegate.newSplitDown(_:)))
            case "pick-terminal", "pick-changes":
                if let blank = git.tabs(in: git.lastRegion).first(where: \.isBlank) {
                    git.fill(blank, with: step == "pick-terminal" ? .terminal : .pane(.changes))
                }
            case "close": send(#selector(AppDelegate.closeSession(_:)))
            case "column": send(#selector(AppDelegate.toggleSideColumn(_:)))
            case "strip": send(#selector(AppDelegate.toggleBottomStrip(_:)))
            case "sidebar": send(#selector(AppDelegate.toggleSessionSidebar(_:)))
            case "next": send(#selector(AppDelegate.selectNextSession(_:)))
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "wide":
                treeView(in: controller)?.dragDivider(0, by: 80)
            case let pick where pick.hasPrefix("select:"):
                // The nth tab of the row you're in to the front, as ⌥⌘ and
                // its number does: for a close from the middle of a row.
                guard let number = Int(pick.dropFirst("select:".count)) else { continue }
                git.selectTab(number: number, in: git.lastRegion)
            case let size where size.hasPrefix("resize:"):
                // The window to this size in twenty steps over a second, as
                // a drag by its corner would.
                let parts = size.dropFirst("resize:".count).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let window = controller.window
                let from = window.frame
                for stepIndex in 1...20 {
                    let t = CGFloat(stepIndex) / 20
                    let width = from.width + (CGFloat(parts[0]) - from.width) * t
                    let height = from.height + (CGFloat(parts[1]) - from.height) * t
                    window.setFrame(NSRect(x: from.minX, y: from.maxY - height, width: width, height: height),
                                    display: true)
                    await pause(0.05)
                }
            case let drop where drop.hasPrefix("drop:"):
                let landed = self.drop(String(drop.dropFirst("drop:".count)), controller)
                await pause(1.2)
                var entry = state(manager, controller)
                entry["step"] = step
                entry["landed"] = landed
                trail.append(entry)
                continue
            case let key where key.hasPrefix("key:"):
                // A key as the terminal meets it: first what libghostty
                // would do with it ahead of the menu, then the menu.
                let landed = press(String(key.dropFirst("key:".count)), manager, controller)
                await pause(1.2)
                var entry = state(manager, controller)
                entry["step"] = step
                entry["landed"] = landed
                trail.append(entry)
                continue
            case "trace-blank", "trace-tab", "trace-close":
                // A tab added to the row you're in, and the row's motion
                // sampled through the animation: what moves that should not.
                let region = git.lastRegion
                let strip = controller.split.mainArea?.rows.first { $0.region == region }?.strip
                var samples = ["before  " + (strip?.motionSample ?? "no row")]
                switch step {
                case "trace-blank": git.openBlank(in: region)
                case "trace-close": send(#selector(AppDelegate.closeSession(_:)))
                default: send(#selector(AppDelegate.newTerminalHere(_:)))
                }
                for index in 0..<14 {
                    await pause(0.02)
                    samples.append(String(format: "%3dms  ", (index + 1) * 20) + (strip?.motionSample ?? ""))
                }
                await pause(0.8)
                samples.append("after   " + (strip?.motionSample ?? ""))
                var entry = state(manager, controller)
                entry["step"] = step
                entry["landed"] = "\n      " + samples.joined(separator: "\n      ")
                trail.append(entry)
                continue
            case let typed where typed.hasPrefix("type:"):
                // A plain key to whatever has the keyboard in the window, as
                // the window would hand it on. Never posted to the system.
                let landed = typeKey(String(typed.dropFirst("type:".count)), controller)
                await pause(1.2)
                var entry = state(manager, controller)
                entry["step"] = step
                entry["landed"] = landed
                trail.append(entry)
                continue
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

    /// Let go of the tab in front of the area you're in over a split: `spec`
    /// is `<n>.<where>`.
    @MainActor
    private static func drop(_ spec: String, _ controller: MainWindowController) -> String {
        let parts = spec.split(separator: ".").map(String.init)
        let frames = controller.split.mainArea?.paneFrames ?? []
        guard parts.count == 2, let index = Int(parts[0]), frames.indices.contains(index) else {
            return "no such split"
        }
        let git = controller.gitPanel
        guard let tab = git.activeTab(in: git.lastRegion) else { return "no tab in front" }
        // Window coordinates: up is a larger y.
        let frame = frames[index].frame
        let point: NSPoint
        switch parts[1] {
        case "left": point = NSPoint(x: frame.minX + 10, y: frame.midY)
        case "right": point = NSPoint(x: frame.maxX - 10, y: frame.midY)
        case "up": point = NSPoint(x: frame.midX, y: frame.maxY - Chrome.titlebarHeight - 10)
        case "down": point = NSPoint(x: frame.midX, y: frame.minY + 10)
        default: point = NSPoint(x: frame.midX, y: frame.midY)
        }
        return controller.split.probeDrop(tab, at: point)
    }

    /// Type one plain key (`c`, `return`, `escape`, `down`) at the window's
    /// first responder. Says what kind of view had the keyboard.
    @MainActor
    private static func typeKey(_ key: String, _ controller: MainWindowController) -> String {
        let codes: [String: UInt16] = ["t": 17, "b": 11, "c": 8, "h": 4, "f": 3, "x": 7,
                                       "return": 36, "escape": 53, "down": 125, "up": 126]
        guard let code = codes[key.lowercased()],
              let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let event = NSEvent(cgEvent: cgEvent) else { return "no such key" }
        let responder = controller.window.firstResponder
        let name = responder.map { String(describing: type(of: $0)) } ?? "nothing"
        // Through the window, as a real key comes: SwiftUI's key handling
        // hangs off that path, not off `keyDown` on the responder.
        controller.window.sendEvent(event)
        return "to \(name), window key: \(controller.window.isKeyWindow)"
    }

    /// Press `chord` (`shift+cmd+c`): a key-down made here, never sent
    /// through the system, so it reaches no other app. Says who took it. A
    /// key the session's terminal would take ahead of the menu is a fault:
    /// the menu's command never runs and the letter is typed instead.
    @MainActor
    private static func press(_ chord: String, _ manager: SessionManager,
                              _ controller: MainWindowController) -> String {
        let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "c": 8, "b": 11,
                                       "e": 14, "t": 17, "1": 18, "2": 19, "3": 20, "l": 37, "j": 38]
        var flags: NSEvent.ModifierFlags = []
        var letter = ""
        for part in chord.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            case "alt": flags.insert(.option)
            default: letter = part
            }
        }
        guard let code = codes[letter] else { return "no such key" }
        // Made the way the system makes one, so its characters are what a
        // real key gives (with ⌘ held they are not what you would guess),
        // and never posted: it exists only in this process.
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return "no event" }
        cgEvent.flags = cgFlags
        guard let event = NSEvent(cgEvent: cgEvent) else { return "no event" }
        if manager.selected?.surfaceView?.takesAheadOfMenu(event) == true {
            return "FAULT the terminal takes it ahead of the menu"
        }
        guard let menu = NSApp.mainMenu else { return "no menu" }
        return menu.performKeyEquivalent(with: event) ? "the menu" : "FAULT nothing takes it"
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
