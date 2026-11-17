import AppKit

/// Owns the preview windows. One per file, and that's the whole model.
///
/// An earlier version had windows that followed the selection, with a pin to
/// stop one following — Xcode's preview-tab rule. It was a worse idea than it
/// sounded: two gestures meant three states, and "why did this window change
/// under me" is a question a preview should never provoke. Double-click opens a
/// window and focuses it; the same file twice focuses the one already open.
@MainActor
final class PreviewWindows {
    private var windows: [PreviewWindowController] = []
    /// Injected rather than reached for, so anything that compiles this doesn't
    /// drag ~20 tree-sitter grammars in behind it.
    private let highlighter: (any DiffHighlighting)?
    /// Where the next window's top-left goes, so windows step off each other
    /// rather than stacking exactly. Done by hand: `cascadeTopLeft(from:)`
    /// measured as a no-op here — it treats `NSZeroPoint` as "don't move me",
    /// and every window after the first landed on the same centred spot, so
    /// three open files looked like one.
    private var nextTopLeft: NSPoint?
    /// One reading size for every preview; ⌘+ in any window moves all of them.
    private let settings = PreviewSettings()
    /// How a file reached *from* a preview is opened — a link in a rendered
    /// README to the file next to it. Routed back out to the app's one opener
    /// rather than calling `open` here, so a linked file gets the same diff
    /// treatment as one double-clicked in the tree.
    var onOpenFile: ((URL) -> Void)?
    /// A window dragged by its row, the pointer on screen: whether it's over
    /// one of the main window's tab rows, and on `.ended` whether it became
    /// a tab there (MainSplitViewController.dockWindowDrag). Handed the
    /// document, so the tab keeps the window's diff and view.
    var onDock: ((TabDragController.DockPhase, PreviewDocument, NSWindow, NSPoint) -> Bool)?

    init(highlighter: (any DiffHighlighting)? = nil) {
        self.highlighter = highlighter
    }

    /// Show `url` in a window and put it in front. Opening a file that already
    /// has a window focuses that one rather than making a second — including
    /// when it's reached from somewhere else, so a file opened from the tree and
    /// then from the Changes list is still one window.
    /// Focus the window already showing `url`, if there is one. Returns whether
    /// it did, so a caller can skip the work of deciding how to open it.
    @discardableResult
    func focus(_ url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard let existing = windows.first(where: { $0.file.url == url }) else { return false }
        existing.showWindow(nil)
        return true
    }

    /// `topLeft`, in screen coordinates, puts the window there rather than on
    /// the cascade: a tab dragged out of the main window lands where it was
    /// let go.
    func open(_ url: URL, diff: PreviewDiffSource = .none, hasChanges: Bool = false,
              mode preferred: PreviewMode? = nil, at topLeft: NSPoint? = nil) {
        // Identity is the resolved path — two aliases to one file are one window
        // — but the document is handed the path as *asked for*, so it can say the
        // file lives somewhere else. It resolves for itself.
        if focus(url) { return }

        // The view it was on as a tab, when it was one; else the inferred one.
        let resolved = url.resolvingSymlinksInPath()
        let mode = preferred.flatMap {
            PreviewMode.available(for: resolved, hasDiffSource: diff.exists).contains($0) ? $0 : nil
        } ?? PreviewMode.inferred(for: resolved, hasChanges: hasChanges, hasDiffSource: diff.exists)
        // The view it opened on, which is the only question here worth asking:
        // Rendered Markdown, a diff and plain source are three different
        // features sharing one window. The file this is about is never named.
        Telemetry.capture(.previewOpened(mode: PreviewKind(mode), where: .window))

        let document = PreviewDocument(
            url: url,
            diffSource: diff,
            mode: mode,
            highlighter: highlighter)
        let controller = PreviewWindowController(document: document, settings: settings,
                                                 openFile: onOpenFile)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        controller.onDock = { [weak self] phase, document, window, point in
            self?.onDock?(phase, document, window, point) ?? false
        }
        if let window = controller.window {
            if let topLeft { put(window, at: topLeft) } else { place(window) }
        }
        windows.append(controller)
        controller.showWindow(nil)
    }

    /// Previews are accessories: when the main window goes, so do they, and the
    /// app quits as it always has rather than lingering as a terminal with no
    /// terminal in it.
    func closeAll() {
        for window in windows { window.close() }
        windows.removeAll()
        nextTopLeft = nil
    }

    /// At a point the person chose, kept on the screen it's on: let go near
    /// an edge, the window moves in until all of its row can be reached.
    /// The screen is the pointer's, not the corner's: the corner sits up and
    /// to the left of where the tab was let go, and near a display's edge it
    /// is on the display next door.
    private func put(_ window: NSWindow, at topLeft: NSPoint) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main
        var point = topLeft
        if let visible = screen?.visibleFrame {
            let size = window.frame.size
            point.x = min(max(point.x, visible.minX), visible.maxX - size.width)
            point.y = min(max(point.y, visible.minY + size.height), visible.maxY)
        }
        window.setFrameTopLeftPoint(point)
    }

    /// Step this window down-right of the last one, and start over from centre
    /// once the stair would walk off the screen.
    private func place(_ window: NSWindow) {
        if let point = nextTopLeft { window.setFrameTopLeftPoint(point) }
        let frame = window.frame
        let next = NSPoint(x: frame.minX + 26, y: frame.maxY - 26)
        // `window.screen` is nil until a window has been shown, so the screen is
        // only consulted for the wrap — never as a precondition for moving, or
        // the first window's placement (and every one after it) is skipped.
        let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let wouldFit = visible.map {
            $0.contains(NSPoint(x: next.x + frame.width, y: next.y - frame.height))
        } ?? false
        nextTopLeft = wouldFit ? next : nil
    }
}
