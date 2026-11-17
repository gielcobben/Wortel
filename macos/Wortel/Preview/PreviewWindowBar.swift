import AppKit
import SwiftUI

/// A preview window's titlebar row: the main window's kind of row, not the
/// system's.
///
/// The window used to keep the system titlebar, with the mode control as a
/// toolbar item. On macOS 26 and later that put the control on a Liquid Glass
/// capsule over a grey bar with a separator under it: a window from another
/// app, next to a main window that draws its own rows (TitleBars.swift). This
/// is one of those rows, and the file tab's header laid into it: the file's
/// icon and name, and Diff · Source · Rendered in the same switch the tab uses.
///
/// Laid out as the main row is with the sidebar collapsed: the first control
/// at the traffic lights' inset, the name 8pt after it.
///
/// Empty space moves the window and double-click zooms it (`ChromeBarView`);
/// the name is a `PassthroughLabel` so a press on it does the same, as a title
/// does.
@MainActor
final class PreviewWindowBar: ChromeBarView {
    /// A press on the row's empty space, about to move the window.
    var onWindowDrag: () -> Void = {}

    init(document: PreviewDocument) {
        super.init()

        let icon = FileButton(url: document.url)
        let name = PassthroughLabel(labelWithString: document.requestedURL.lastPathComponent)
        // The session name's font in the main window's row (MainBar).
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The tab's own switch, hosted. It hides itself for a binary file and
        // for a file with one mode, as the tab's does: absent, not greyed.
        let modes = NSHostingView(rootView: PreviewWindowModeSwitch(document: document))
        modes.sizingOptions = [.intrinsicContentSize]
        modes.safeAreaRegions = []

        for view in [icon, name, modes] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.trafficLightInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            modes.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            modes.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            modes.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onWindowDrag() }
        super.mouseDown(with: event)
    }
}

/// The mode switch, or nothing when there's no choice to make.
private struct PreviewWindowModeSwitch: View {
    @Bindable var document: PreviewDocument

    var body: some View {
        if !document.isBinary, document.availableModes.count > 1 {
            ModeSwitch(modes: document.availableModes, selection: $document.mode)
        }
    }
}

/// The file, as a button of the row: what the system's proxy icon did before
/// the title went, drawn like every other control in the chrome (28pt, the
/// hover and press fills, a 14pt glyph in the secondary colour) rather than
/// as the Finder's full-colour icon, which was the only colour in the row and
/// had no hover.
///
/// Click it for the folders above the file, picking one shows it in the
/// Finder (the system's menu, without needing ⌘). Drag it to drop the file
/// somewhere: into a terminal, its escaped path.
@MainActor
final class FileButton: HoverFillButton, NSDraggingSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: Self.symbol(for: url), accessibilityDescription: "File")?
            .withSymbolConfiguration(Chrome.glyph)
        toolTip = url.path
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Chrome.controlSize),
            heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The file's tab's glyph, from the one place tabs get theirs, so the
    /// file looks the same as a tab and as a window.
    private static func symbol(for url: URL) -> String {
        TitleBarController.stripItem(for: .file(url.path), in: nil).symbol
    }

    /// Click or drag, decided here: past 6pt it's a drag (the tab strip's
    /// threshold), let go before that and it's a click.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isHighlighted = true
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                isHighlighted = false
                if bounds.contains(convert(next.locationInWindow, from: nil)) { showPathMenu() }
                return
            }
            let point = next.locationInWindow
            if hypot(point.x - start.x, point.y - start.y) >= 6 {
                isHighlighted = false
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let picture = NSWorkspace.shared.icon(forFile: url.path)
                picture.size = NSSize(width: 32, height: 32)
                let frame = NSRect(x: (bounds.width - 32) / 2, y: (bounds.height - 32) / 2,
                                   width: 32, height: 32)
                item.setDraggingFrame(frame, contents: picture)
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showPathMenu()
    }

    /// Copy or link, never move: dropped on a Finder window, the file stays
    /// where the agent left it.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    /// The file, then each folder above it to the disk, with the chrome's menu
    /// glyphs rather than the Finder's icons. Under the button, as the row's
    /// other menus open under theirs.
    private func showPathMenu() {
        let menu = NSMenu()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var current = url
        var isFile = true
        while true {
            let target = current
            let item = ClosureMenuItem(title: FileManager.default.displayName(atPath: target.path)) {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            let parent = current.deletingLastPathComponent()
            let isRoot = parent.path == current.path
            item.setGlyph(isFile ? Self.symbol(for: target)
                          : isRoot ? "internaldrive"
                          : target.standardizedFileURL.path == home ? "house" : "folder")
            menu.addItem(item)
            if isRoot { break }
            current = parent
            isFile = false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
