import AppKit
import SwiftUI

/// One preview window: one file, shown as syntax-highlighted source.
///
/// An `NSWindowController` rather than anything SwiftUI offers a window, because
/// the titlebar is the main window's kind (TitleBars.swift): transparent, no
/// title, an empty toolbar for the height and the centred traffic lights, and a
/// row of Wortel's own drawn across the top (`PreviewWindowBar`). The system's
/// titlebar put the mode control on a Liquid Glass capsule over a grey bar, and
/// read as another app's window.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    /// Named `file` rather than `document`: NSWindowController already has a
    /// `document` property, and shadowing it is a compile error worth not
    /// discovering twice.
    let file: PreviewDocument
    /// Called when the window closes, so the registry can forget it.
    var onClose: ((PreviewWindowController) -> Void)?
    /// ⌘F state, owned here because the menu item reaches this object through
    /// the responder chain — a window controller sits in it, after its window.
    private let find = PreviewFind()
    /// Shared with every other preview, so ⌘+ resizes the text in all of them.
    private let settings: PreviewSettings
    /// The window server's own titlebar dragging, kept off while it would
    /// take a press meant for the row (the main window's arrangement).
    private var movability: WindowMovability?

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

    init(document: PreviewDocument,
         settings: PreviewSettings,
         openFile: ((URL) -> Void)? = nil) {
        self.file = document
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Each preview is its own window, as the main window is. System tabs
        // would put the system's tab bar under a titlebar that is no longer the
        // system's, and files already have tabs of their own, in the column.
        window.tabbingMode = .disallowed
        // The main window's titlebar (AppDelegate): transparent so the row under
        // it takes the clicks, no title (the row names the file), no separator
        // (the row draws its own hairline), and an empty compact toolbar for the
        // one thing only it does: the row's height, with the traffic lights
        // centred in it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "wortel.preview")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
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
        let hosting = NSHostingController(
            rootView: PreviewContent(document: document, find: find, settings: settings,
                                     onOpenFile: openFile))
        hosting.sizingOptions = []
        // The main window's layers: one behind-window material, the row on it,
        // and the file as an opaque page under the row's hairline.
        let pane = ChromePaneController(bar: PreviewWindowBar(document: document),
                                        content: hosting, bodyColor: Chrome.content)
        window.contentViewController = BackdropController(child: pane)
        window.contentMinSize = NSSize(width: 360, height: 240)
        // Size is remembered, position is not — deliberately, and *not* through
        // `setFrameAutosaveName`. An autosave name belongs to one window: with
        // several previews open they all write to the same key and each new one
        // restores the last one's frame, so they arrive stacked exactly on top
        // of each other and only the newest is visible. Remembering the size and
        // cascading the position is what a document window does.
        window.setContentSize(Self.rememberedSize)
        window.center()
        // Not shown (the row names the file), but the Window menu and Mission
        // Control still read it.
        window.title = document.url.lastPathComponent
        movability = WindowMovability(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // View ▸ Increase/Decrease/Reset Font Size (⌘+ ⌘− ⌘0). The menu already
    // routes those selectors through the responder chain to whatever implements
    // them — the terminal's SurfaceView in the main window, this controller in a
    // preview. Nothing new is bound, and the terminal keeps its own ⌘+ exactly
    // as before: the menu item simply acts on the window you're looking at.

    @objc func increaseFontSize(_ sender: Any?) { settings.increase() }
    @objc func decreaseFontSize(_ sender: Any?) { settings.decrease() }
    @objc func resetFontSize(_ sender: Any?) { settings.reset() }

    // MARK: - Select All and Copy
    //
    // Source and Diff select natively once the table has focus, which this hands
    // it — a window hosting SwiftUI opens with the window itself as first
    // responder, so ⌘A would otherwise reach nothing. Rendered has no rows, and
    // SwiftUI selects within one `Text`, so there ⌘A means "the document" and ⌘C
    // copies the file. Selecting *part* of a rendered document is what ⌘2 is
    // for: the same file, in a view built for it.

    @objc override func selectAll(_ sender: Any?) {
        if let table = diffTable {
            window?.makeFirstResponder(table)
            table.selectAll(sender)
        } else {
            file.selectsAll = true
        }
    }

    @objc func copy(_ sender: Any?) {
        // Only reached when nothing is focused to answer it — otherwise the
        // table or the text view has already handled ⌘C with its selection.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.plainText, forType: .string)
    }

    /// The diff's table, found the way `SidebarSelectionStyler` finds its own: by
    /// walking the window for the identifier `DiffView` stamps on it. The
    /// alternative is threading a handle back out of a SwiftUI view, which is
    /// more machinery for the same answer.
    private var diffTable: NSTableView? {
        func search(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.identifier == DiffView.tableIdentifier {
                return table
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return window?.contentView.flatMap(search)
    }

    /// Edit ▸ Find (⌘F). Reached through the responder chain, so it's live
    /// exactly when a preview window is key and greyed out everywhere else —
    /// which is why the menu item can carry ⌘F without stealing it from the
    /// terminal, where ⌘F belongs to the shell.
    @objc func showPreviewFind(_ sender: Any?) {
        // Rendered Markdown has no lines to point at, so there's nothing to
        // search; the menu validation below keeps the item disabled there.
        find.isPresented = true
    }

    /// Edit ▸ Find Next / Find Previous (⌘G / ⇧⌘G), while the find bar is up.
    @objc func previewFindNext(_ sender: Any?) { find.next() }
    @objc func previewFindPrevious(_ sender: Any?) { find.previous() }

    /// View ▸ Preview ▸ Diff / Source / Rendered, and the ⌘1…⌘3 that `MainMenu`
    /// lends those items while a preview is key.
    @objc func showPreviewMode(_ sender: NSMenuItem) {
        guard let mode = PreviewMode.mode(menuTag: sender.tag),
              file.availableModes.contains(mode) else { return }
        file.mode = mode
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showPreviewMode(_:)) {
            guard let mode = PreviewMode.mode(menuTag: menuItem.tag) else { return false }
            // A checkmark on the mode you're in: the switch in the row says the
            // same thing, but only the menu can say it while it's open.
            menuItem.state = file.mode == mode ? .on : .off
            return !file.isBinary && file.availableModes.contains(mode)
        }
        if menuItem.action == #selector(previewFindNext(_:))
            || menuItem.action == #selector(previewFindPrevious(_:)) {
            return find.isPresented && !find.matches.isEmpty
        }
        guard menuItem.action == #selector(showPreviewFind(_:)) else { return true }
        // Nothing to search in a rendered document or a Quick Look preview.
        return file.mode != .rendered && !file.isBinary
    }

    /// One size for all previews rather than one per file: you size a preview
    /// once to suit your screen, and every one after it should arrive that way.
    /// Once per gesture, not once per frame of one: `windowDidResize` fires
    /// continuously while a corner is being dragged, and none of those
    /// intermediate sizes is a preference.
    func windowDidEndLiveResize(_ notification: Notification) {
        persistSize()
    }

    func windowWillClose(_ notification: Notification) {
        // Zoom and full-screen resize a window without ever ending a live
        // resize, so closing is the other place the final size is known.
        persistSize()
        movability?.invalidate()
        movability = nil
        onClose?(self)
    }

    private func persistSize() {
        // The *content* size, measured the same way it's applied — mixing a
        // frame size into a content size grows every new window by the height of
        // a titlebar, which compounds on each launch (653 → 681 → 710 …).
        guard let window, window.isVisible else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        guard size.width >= 360, size.height >= 240 else { return }
        UserDefaults.standard.set(Double(size.width), forKey: Self.sizeKey + ".width")
        UserDefaults.standard.set(Double(size.height), forKey: Self.sizeKey + ".height")
    }
}
