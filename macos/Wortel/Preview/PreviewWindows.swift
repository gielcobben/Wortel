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

    func open(_ url: URL, diff: PreviewDiffSource = .none, hasChanges: Bool = false) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if focus(url) { return }

        let document = PreviewDocument(
            url: url,
            diffSource: diff,
            mode: PreviewMode.inferred(for: url, hasChanges: hasChanges, hasDiffSource: diff.exists),
            highlighter: highlighter)
        let controller = PreviewWindowController(document: document, settings: settings)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        if let window = controller.window { place(window) }
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
