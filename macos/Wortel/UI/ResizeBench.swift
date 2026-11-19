#if DEBUG
import AppKit
import IOSurface

/// Resize the window a few hundred times at the display's pace and say what
/// each step cost the main thread.
///
/// A window that follows the pointer has one frame to do everything a new
/// size asks of it: lay out, redraw, commit. At 120 Hz that is 8.3 ms, and a
/// step that takes longer is a frame the edge stands still. Whether a change
/// made that better is not something to judge by eye, and a real drag can't
/// be repeated. This runs the same steps every time.
///
/// Each step sets the window's frame and flushes the transaction, which is
/// where the layout, the terminal's synchronous frame and the commit all
/// happen, and times the two together. It is not a live resize (the window
/// server is not holding the screen for it), so it measures the app's own
/// work and nothing else.
///
/// Debug builds only, addressed by pid like `AppearanceTestHook`. The object
/// is the file the result is written to, as JSON:
///
///     osascript -l JavaScript -e 'ObjC.import("Foundation");
///       $.NSDistributedNotificationCenter.defaultCenter
///        .postNotificationNameObjectUserInfoDeliverImmediately(
///          "sh.wortel.test.resize.<pid>", "/tmp/resize.json", $(), true)'
///
/// `macos/scripts/bench-resize.sh` wraps it in a throwaway copy.
enum ResizeBench {
    private static var observer: NSObjectProtocol?
    private static var timer: DispatchSourceTimer?

    /// Points a step moves the edge: 360 a second at 120 Hz, an unhurried drag.
    private static let stepWidth: CGFloat = 3
    private static let stepHeight: CGFloat = 2
    /// Steps in one direction, so the window loses 360 by 240 points at most.
    private static let reach = 120
    private static let interval = 1.0 / 120

    static func install() {
        let name = Notification.Name("sh.wortel.test.resize.\(ProcessInfo.processInfo.processIdentifier)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { run(writingTo: path) }
        }
    }

    @MainActor
    private static func run(writingTo request: String) {
        // "path", then any of: "before" for a frame on every change of
        // size, as libghostty has it and Wortel had until 2026-11-19, and
        // "column" to open the side column first.
        let parts = request.split(separator: "|").map(String.init)
        let path = parts[0]
        let before = parts.contains("before")
        if SurfaceView.frameOnEveryResize != before { SurfaceView.frameOnEveryResize = before }
        if parts.contains("column"), columnIsShut() {
            NSApp.sendAction(#selector(AppDelegate.toggleSideColumn(_:)), to: nil, from: nil)
            // Again once it has opened: everything below reads the layout.
            let rest = parts.filter { $0 != "column" }.joined(separator: "|")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(writingTo: rest) }
            return
        }
        guard timer == nil,
              let window = NSApp.windows
                .filter({ $0.isVisible && $0.styleMask.contains(.resizable) })
                .max(by: { $0.frame.width < $1.frame.width })
        else { return }
        let original = window.frame
        // Room for the terminal to give up `reach` steps and stay a terminal:
        // squeezed to nothing, its pane stops shrinking and the one beside
        // it folds away, and the round measures that instead.
        if let terminal = shownTerminal(in: window.contentView) {
            let short = stepWidth * CGFloat(reach) + 240 - terminal.frame.width
            if short > 0 {
                var wider = original
                wider.size.width += short
                if let screen = window.screen { wider.origin.x = max(screen.visibleFrame.minX, min(wider.origin.x, screen.visibleFrame.maxX - wider.width)) }
                window.setFrame(wider, display: true)
            }
        }
        let start = window.frame
        // Width alone, there and back, then width and height together: a
        // terminal gains columns far more often than rows.
        var widthOnly: [Double] = []
        var both: [Double] = []
        var divider: [Double] = []
        var step = 0
        // Steps that began with the terminal still showing a frame of an
        // older size: the one for the step before had not landed.
        var stale = 0
        var late = 0
        let terminal = shownTerminal(in: window.contentView)
        // A third round when there is a pane beside the terminal: the
        // divider between the two, dragged. The window keeps its size and
        // both panes change theirs at every step.
        let split = terminal.flatMap(dividerBesideTerminal)
        let dividerStart = split.map { $0.view.arrangedSubviews[$0.divider].frame.maxX } ?? 0
        let total = reach * (split == nil ? 4 : 6)

        // Everything the main thread does between one step and the next is
        // that step's cost: the layout and the commit, and whatever they put
        // off to a later turn of the run loop (SwiftUI does). So the time
        // counted is the time the run loop is awake.
        var awakeSince: CFTimeInterval? = CACurrentMediaTime()
        var busy: Double = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
            true, CFIndex.max
        ) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                awakeSince = now
            } else if let since = awakeSince {
                busy += (now - since) * 1000
                awakeSince = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        func isStale() -> Bool {
            guard let layer = terminal?.layer, let contents = layer.contents,
                  CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return false }
            let surface = contents as! IOSurfaceRef
            let wanted = (Int(layer.bounds.width * layer.contentsScale),
                          Int(layer.bounds.height * layer.contentsScale))
            return (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)) != wanted
        }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.5, repeating: interval)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                // Close the books on the step before: awake until now.
                if let since = awakeSince { busy += (now - since) * 1000 }
                awakeSince = now
                if step > 0 {
                    switch (step - 1) / (reach * 2) {
                    case 0: widthOnly.append(busy)
                    case 1: both.append(busy)
                    default: divider.append(busy)
                    }
                }
                busy = 0
                guard step < total else {
                    source.cancel()
                    timer = nil
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                    window.setFrame(original, display: true)
                    write(["widthOnly": summary(widthOnly), "widthAndHeight": summary(both),
                           "divider": summary(divider),
                           "budgetMs": interval * 1000, "staleFrames": stale, "lateTerminal": late,
                           "mode": SurfaceView.frameOnEveryResize ? "before" : "now"], to: path)
                    return
                }
                if isStale() { stale += 1 }
                let phase = step / (reach * 2)
                let within = step % (reach * 2)
                let distance = CGFloat(within < reach ? within + 1 : reach * 2 - within - 1)
                let before = terminal?.frame.size
                if phase == 2, let split {
                    // Towards the terminal: the pane beside it grows.
                    // A third as far, three times: the pane has a widest.
                    let third = reach / 3
                    let lap = within % (third * 2)
                    let moved = CGFloat(lap < third ? lap + 1 : third * 2 - lap - 1)
                    split.view.setPosition(dividerStart - moved * stepWidth * split.towardsTerminal,
                                           ofDividerAt: split.divider)
                    split.view.layoutSubtreeIfNeeded()
                } else {
                    var frame = start
                    frame.size.width = start.width - distance * stepWidth
                    if phase == 1 {
                        frame.size.height = start.height - distance * stepHeight
                        // The top edge stays put, as it does under a drag from below.
                        frame.origin.y = start.maxY - frame.size.height
                    }
                    window.setFrame(frame, display: true)
                }
                CATransaction.flush()
                // The terminal's own view had not taken its new size by the
                // time the window's frame was committed.
                if terminal?.frame.size == before { late += 1 }
                step += 1
            }
        }
        timer = source
        source.resume()
    }

    @MainActor
    private static func columnIsShut() -> Bool {
        for window in NSApp.windows {
            guard let terminal = shownTerminal(in: window.contentView) else { continue }
            return dividerBesideTerminal(terminal) == nil
        }
        return false
    }

    /// The split view the terminal's pane is in, and the divider between
    /// that pane and one beside it that is open and is not the sidebar.
    @MainActor
    private static func dividerBesideTerminal(
        _ terminal: SurfaceView
    ) -> (view: NSSplitView, divider: Int, towardsTerminal: CGFloat)? {
        var view: NSView? = terminal
        while let current = view {
            if let split = current.superview as? NSSplitView, split.isVertical,
               split.delegate is MainSplitViewController,
               let index = split.arrangedSubviews.firstIndex(of: current) {
                let panes = split.arrangedSubviews
                func open(_ i: Int) -> Bool { panes.indices.contains(i) && !split.isSubviewCollapsed(panes[i]) && panes[i].frame.width > 1 }
                // The sidebar is the first pane; the column is on either side.
                if open(index + 1) { return (split, index, 1) }
                if index - 1 > 0, open(index - 1) { return (split, index - 1, -1) }
                return nil
            }
            view = current.superview
        }
        return nil
    }

    /// The largest terminal on screen: the session's own, not a side one.
    @MainActor
    private static func shownTerminal(in view: NSView?) -> SurfaceView? {
        guard let view, !view.isHidden else { return nil }
        if let terminal = view as? SurfaceView { return terminal }
        return view.subviews.compactMap { shownTerminal(in: $0) }
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private static func summary(_ costs: [Double]) -> [String: Any] {
        guard !costs.isEmpty else { return [:] }
        let sorted = costs.sorted()
        func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return [
            "steps": costs.count,
            "meanMs": rounded(costs.reduce(0, +) / Double(costs.count)),
            "medianMs": rounded(at(0.5)),
            "p95Ms": rounded(at(0.95)),
            "maxMs": rounded(sorted[sorted.count - 1]),
            "overBudget": costs.filter { $0 > interval * 1000 }.count,
        ]
    }

    private static func write(_ result: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
