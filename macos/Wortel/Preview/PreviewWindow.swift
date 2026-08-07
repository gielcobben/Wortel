import AppKit
import SwiftUI

/// One preview window: a file, and the toolbar that decides how it's shown.
///
/// An `NSWindowController` rather than anything SwiftUI offers a window, because
/// the details that make this feel native are AppKit's: `representedURL` for the
/// proxy icon (⌘-click it for the path hierarchy, drag it into the terminal —
/// `SurfaceView` already accepts a `.fileURL` and inserts the escaped path), a
/// subtitle for the path so the title stays just the filename, and a tabbing
/// identifier so a second window merges into tabs on its own.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    /// Named `file` rather than `document`: NSWindowController already has a
    /// `document` property, and shadowing it is a compile error worth not
    /// discovering twice.
    let file: PreviewDocument
    /// Pinned windows stop following the selection. Observed by `PreviewWindows`
    /// to decide which window a retarget goes to.
    private(set) var isPinned: Bool
    /// Called when the window closes, so the registry can forget it.
    var onClose: ((PreviewWindowController) -> Void)?

    private var pinItem: NSToolbarItem?

    init(document: PreviewDocument, pinned: Bool) {
        self.file = document
        self.isPinned = pinned

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.tabbingIdentifier = "wortel.preview"
        window.tabbingMode = .preferred
        // A glance, not state: relaunching shouldn't reopen yesterday's files,
        // and this app's launch time is a feature.
        window.isRestorable = false
        super.init(window: window)

        window.delegate = self
        // Content first, *then* the size — in that order, and not the other way
        // round. Assigning a contentViewController resizes the window to fit its
        // view, and a SwiftUI root with flexible frames has an ideal size of
        // nothing: measured, a 720×640 window becomes 1×1 the moment the hosting
        // controller lands. That is a window that opens perfectly and cannot be
        // seen, which looks exactly like a double-click doing nothing.
        window.contentViewController = NSHostingController(
            rootView: PreviewContent(document: document))
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.setContentSize(NSSize(width: 720, height: 640))
        window.center()
        window.setFrameAutosaveName("preview")
        // The autosave restores whatever was last saved — including, once, a
        // collapsed frame. A degenerate one is not a preference.
        if window.frame.width < window.contentMinSize.width
            || window.frame.height < window.contentMinSize.height {
            window.setContentSize(NSSize(width: 720, height: 640))
            window.center()
        }
        applyIdentity()
        installToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Title, subtitle and proxy icon, all from the file itself.
    private func applyIdentity() {
        guard let window else { return }
        window.title = file.url.lastPathComponent
        window.subtitle = file.url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // The proxy icon. Set last: AppKit reads the title from it otherwise.
        window.representedURL = file.url
    }

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        pinItem?.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Pinned" : "Pin")
    }

    @objc private func togglePin() {
        setPinned(!isPinned)
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "wortel.preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

// MARK: - Toolbar

extension PreviewWindowController: NSToolbarDelegate {
    private static let pinIdentifier = NSToolbarItem.Identifier("wortel.preview.pin")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pinIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.pinIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Pin"
        // Says what it's *for*, not what it is: the window following your
        // selection is the surprising half, so the tooltip explains that.
        item.toolTip = "Keep this file — stop following the selection"
        item.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin",
                             accessibilityDescription: "Pin")
        item.target = self
        item.action = #selector(togglePin)
        item.isBordered = true
        pinItem = item
        return item
    }
}
