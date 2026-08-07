import AppKit
import SwiftUI

/// One preview window: one file, shown as syntax-highlighted source.
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
    /// Called when the window closes, so the registry can forget it.
    var onClose: ((PreviewWindowController) -> Void)?

    private static let defaultSize = NSSize(width: 720, height: 640)
    private static let sizeKey = "preview.size"

    /// The size the last preview was left at, clamped so a frame saved by an
    /// older, buggier build can't resurrect a window you can't see.
    private static var rememberedSize: NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: sizeKey + ".width")
        let height = defaults.double(forKey: sizeKey + ".height")
        guard width >= 360, height >= 240 else { return defaultSize }
        return NSSize(width: width, height: height)
    }

    init(document: PreviewDocument) {
        self.file = document

        // No `.fullSizeContentView`: there's no toolbar to run the content under,
        // and with an ordinary titlebar it would hide the file's first lines
        // behind it.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Previews tab with each other, but only if the *system* says so.
        // `.preferred` forces tabbing regardless of System Settings, which on a
        // default Mac ("tabs in full screen only") silently merged every preview
        // into one window: three open files shared a frame and only the selected
        // one was on screen, which looks exactly like opening a second file
        // doing nothing.
        window.tabbingIdentifier = "wortel.preview"
        window.tabbingMode = .automatic
        // Where a window *lands* is as much a way to be invisible as how big it
        // is. A new window opens on the space the app was launched in, so with
        // the terminal full-screen it appears on another space entirely —
        // opened perfectly, and not on the screen you're looking at.
        // `.moveToActiveSpace` puts it where you are; `.fullScreenAuxiliary`
        // lets it sit over a full-screen window rather than behind it.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // A glance, not state: relaunching shouldn't reopen yesterday's files,
        // and this app's launch time is a feature.
        window.isRestorable = false
        super.init(window: window)
        // Off, or AppKit repositions the window when it's shown and undoes the
        // placement `PreviewWindows` just made. Its own cascade can't do the job
        // either: each preview has its own controller, and a controller only
        // cascades against windows *it* has shown — so every window lands on the
        // same spot and three open files look like one.
        shouldCascadeWindows = false

        window.delegate = self

        // **The window's size is the window's business.** A hosting controller
        // resizes its window to fit its content by default, and a SwiftUI root
        // of flexible frames has an ideal size of *nothing* — so the window
        // collapses to 1×1 the moment the controller is assigned, and then walks
        // a few points smaller on every layout pass after that (725 → 723 → 709,
        // measured against the window server). It opens perfectly and cannot be
        // seen, which looks exactly like a double-click doing nothing. Same
        // idiom the sidebar's hosted rows already use.
        let hosting = NSHostingController(rootView: PreviewContent(document: document))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 360, height: 240)
        // Size is remembered, position is not — deliberately, and *not* through
        // `setFrameAutosaveName`. An autosave name belongs to one window: with
        // several previews open they all write to the same key and each new one
        // restores the last one's frame, so they arrive stacked exactly on top
        // of each other and only the newest is visible. Remembering the size and
        // cascading the position is what a document window does.
        window.setContentSize(Self.rememberedSize)
        window.center()
        applyIdentity()
        installToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: - Mode control
    //
    // A segmented control in the titlebar, and only when there's a choice to
    // make: one mode is not a control, it's a decoration that costs a row of
    // titlebar. Its look is borrowed from the inspector's pane control on
    // purpose — the two answer the same kind of question and should read as one
    // vocabulary.

    private weak var modeControl: NSSegmentedControl?

    private func installToolbar() {
        guard file.availableModes.count > 1 else { return }
        let toolbar = NSToolbar(identifier: "wortel.preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = file.availableModes
        guard modes.indices.contains(sender.selectedSegment) else { return }
        file.mode = modes[sender.selectedSegment]
    }

    /// Title, subtitle and proxy icon, all from the file itself.
    private func applyIdentity() {
        guard let window else { return }
        window.title = file.url.lastPathComponent
        window.subtitle = file.url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // The proxy icon. Set last: AppKit reads the title from it otherwise.
        window.representedURL = file.url
    }

    /// One size for all previews rather than one per file: you size a preview
    /// once to suit your screen, and every one after it should arrive that way.
    func windowDidResize(_ notification: Notification) {
        // The *content* size, measured the same way it's applied — mixing a
        // frame size into a content size grows every new window by the height of
        // a titlebar, which compounds on each launch (653 → 681 → 710 …).
        guard let window, window.isVisible else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        guard size.width >= 360, size.height >= 240 else { return }
        UserDefaults.standard.set(Double(size.width), forKey: Self.sizeKey + ".width")
        UserDefaults.standard.set(Double(size.height), forKey: Self.sizeKey + ".height")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

// MARK: - Toolbar

extension PreviewWindowController: NSToolbarDelegate {
    private static let modeIdentifier = NSToolbarItem.Identifier("wortel.preview.mode")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.modeIdentifier else { return nil }
        let modes = file.availableModes
        let control = NSSegmentedControl(
            images: modes.map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage()
            },
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:)))
        control.segmentStyle = .automatic
        // Neutral grey rather than the accent tint AppKit gives a selected
        // segment — the same choice the inspector's pane control makes, and for
        // the same reason: this says "what you're looking at", not "this is
        // selected".
        control.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        for (index, mode) in modes.enumerated() {
            control.setToolTip(mode.title, forSegment: index)
        }
        control.selectedSegment = modes.firstIndex(of: file.mode) ?? 0
        modeControl = control

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = control
        item.label = "View"
        item.visibilityPriority = .high
        return item
    }
}
