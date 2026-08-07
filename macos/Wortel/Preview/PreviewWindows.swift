import AppKit

/// Owns the preview windows and the one rule that governs them:
///
/// > At most one window is *tracking*. Every other one is pinned.
///
/// The tracking window is the one a selection change retargets. Nothing else
/// follows anything, which is what keeps arrowing through a file tree from
/// flinging windows across the screen — a window is only ever summoned by a
/// deliberate act (`open`), never by navigation (`retarget`).
@MainActor
final class PreviewWindows {
    private var windows: [PreviewWindowController] = []
    /// Injected rather than reached for, so the unit tests that compile this
    /// don't drag ~20 tree-sitter grammars in behind it.
    private let highlighter: (any DiffHighlighting)?

    init(highlighter: (any DiffHighlighting)? = nil) {
        self.highlighter = highlighter
    }

    private var tracking: PreviewWindowController? {
        windows.first { !$0.isPinned }
    }

    /// A deliberate open: a double-click, a ⌘-clicked path, a Changes row.
    ///
    /// Reuses the tracking window when there is one — the same window walking to
    /// a new file, which is what makes this feel like one preview rather than a
    /// pile of them. `pinned` is the ⌥ path: open it and leave it alone.
    func open(_ url: URL, pinned: Bool = false) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        // Already showing it somewhere: bring that window forward rather than
        // making a second one for the same file.
        if let existing = windows.first(where: { $0.file.url == url }) {
            existing.showWindow(nil)
            if pinned { existing.setPinned(true) }
            return
        }
        if !pinned, let tracking {
            replace(tracking, with: url)
            tracking.showWindow(nil)
            return
        }
        present(url, pinned: pinned)
    }

    /// A selection moved. Only the tracking window cares, and only if one is
    /// already open — this must never summon a window.
    func retarget(_ url: URL) {
        guard let tracking else { return }
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard tracking.file.url != url else { return }
        replace(tracking, with: url)
    }

    /// Whether anything is following the selection — the cheap check callers use
    /// before doing the work of resolving a URL to hand over.
    var isTracking: Bool { tracking != nil }

    /// Previews are accessories: when the main window goes, so do they, and the
    /// app quits as it always has rather than lingering as a terminal with no
    /// terminal in it.
    func closeAll() {
        for window in windows { window.close() }
        windows.removeAll()
    }

    // MARK: - Private

    /// A window shows a different file by taking a new document — the old one's
    /// watcher and content go with it, so nothing accumulates as you scrub.
    private func replace(_ controller: PreviewWindowController, with url: URL) {
        guard let index = windows.firstIndex(where: { $0 === controller }) else { return }
        let wasKey = controller.window?.isKeyWindow ?? false
        let frame = controller.window?.frame
        controller.onClose = nil
        controller.close()
        windows.remove(at: index)
        let replacement = present(url, pinned: false, frame: frame, activate: wasKey)
        windows.remove(at: windows.count - 1)
        windows.insert(replacement, at: index)
    }

    @discardableResult
    private func present(_ url: URL, pinned: Bool,
                         frame: NSRect? = nil, activate: Bool = true) -> PreviewWindowController {
        let document = PreviewDocument(url: url, highlighter: highlighter)
        let controller = PreviewWindowController(document: document, pinned: pinned)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        if let frame { controller.window?.setFrame(frame, display: false) }
        windows.append(controller)
        if activate {
            controller.showWindow(nil)
        } else {
            controller.window?.orderFront(nil)
        }
        return controller
    }
}
