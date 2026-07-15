import AppKit
import SwiftUI

/// Renders a unified diff as an `NSTableView` — one row per line — so even a
/// several-thousand-line diff scrolls smoothly (the table only realizes visible
/// rows). Each row is a single custom view that draws its own tint, gutter line
/// numbers, and monospaced code, with no per-row Auto Layout. This is the same
/// "drop to AppKit where SwiftUI would choke" move the rest of the shell makes.
struct DiffView: NSViewRepresentable {
    let lines: [DiffLine]
    let fontSize: CGFloat

    /// Marks this table so the sidebar's SidebarSelectionStyler (which walks the
    /// whole window for NSTableViews) skips it — otherwise it would wire this
    /// diff table's double-click to session-rename and disable its styling.
    static let tableIdentifier = NSUserInterfaceItemIdentifier("WortelDiffTable")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        context.coordinator.configure(font: font)

        let table = NSTableView()
        table.identifier = Self.tableIdentifier
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.rowHeight = context.coordinator.rowHeight
        table.intercellSpacing = .zero
        table.allowsColumnResizing = false

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = []
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Follow live width changes so the row tints keep filling the panel as
        // it (or the window) is resized.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.observeResize(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let changed = context.coordinator.update(lines: lines)
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.applyColumnWidth()
        table.reloadData()
        if changed {
            // New file selected — jump back to the top.
            table.scroll(.zero)
            scroll.contentView.scroll(to: .zero)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("diff")
        private static let cellID = NSUserInterfaceItemIdentifier("diffCell")

        private(set) var lines: [DiffLine] = []
        private(set) var rowHeight: CGFloat = 16
        private(set) var columnWidth: CGFloat = 400
        private var gutterWidth: CGFloat = 60
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var charWidth: CGFloat = 7
        weak var table: NSTableView?
        private weak var scroll: NSScrollView?

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Watch the scroll view's clip view so the column can be re-widened to
        /// fill the viewport whenever the panel resizes.
        func observeResize(of scroll: NSScrollView) {
            self.scroll = scroll
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportResized),
                name: NSView.frameDidChangeNotification, object: scroll.contentView)
        }

        @objc private func viewportResized() { applyColumnWidth() }

        /// The single column spans at least the full viewport so each row's
        /// background tint fills the panel edge-to-edge; when the content is
        /// wider it stays content-width and the horizontal scroller appears.
        func applyColumnWidth() {
            guard let table else { return }
            let viewport = scroll?.contentView.bounds.width ?? 0
            table.tableColumns.first?.width = max(columnWidth, viewport)
        }

        func configure(font: NSFont) {
            self.font = font
            charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
        }

        /// Returns true when the line set actually changed (new file shown).
        func update(lines: [DiffLine]) -> Bool {
            let changed = lines.count != self.lines.count
                || zip(lines, self.lines).contains { $0.id != $1.id || $0.text != $1.text }
            self.lines = lines
            recomputeGeometry()
            return changed
        }

        private func recomputeGeometry() {
            var maxNo = 1
            var maxChars = 0
            for line in lines {
                maxNo = max(maxNo, line.oldLine ?? 0, line.newLine ?? 0)
                // +1 for the sign column; tabs expand to DiffLineCellView.tabWidth.
                let expanded = line.text.reduce(0) { $0 + ($1 == "\t" ? DiffLineCellView.tabWidth : 1) }
                maxChars = max(maxChars, expanded + 1)
            }
            let digits = max(2, String(maxNo).count)
            let numColumn = CGFloat(digits) * charWidth + 10
            gutterWidth = numColumn * 2 + 6
            columnWidth = gutterWidth + CGFloat(maxChars) * charWidth + 16
        }

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? DiffLineCellView
                ?? DiffLineCellView(identifier: Self.cellID)
            cell.font = font
            cell.charWidth = charWidth
            cell.gutterWidth = gutterWidth
            cell.line = lines[row]
            return cell
        }
    }
}

/// One diff line, drawn by hand: background tint, two right-aligned line-number
/// columns in the gutter, then the sign + code in the document's monospaced
/// font. Flipped so y grows downward like text.
final class DiffLineCellView: NSView {
    static let tabWidth = 4

    var line: DiffLine? { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var charWidth: CGFloat = 7
    var gutterWidth: CGFloat = 60

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }

        backgroundColor(for: line.kind).setFill()
        bounds.fill()

        let numColumn = (gutterWidth - 6) / 2
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        if line.kind != .hunkHeader {
            drawRightAligned(line.oldLine.map(String.init) ?? "",
                             attrs: numberAttrs, rightEdge: numColumn - 2)
            drawRightAligned(line.newLine.map(String.init) ?? "",
                             attrs: numberAttrs, rightEdge: numColumn * 2 - 2)
        }

        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor(for: line.kind),
        ]
        let display = expandTabs(sign(for: line.kind) + line.text)
        let x = line.kind == .hunkHeader ? 8 : gutterWidth + 6
        (display as NSString).draw(at: CGPoint(x: x, y: 1), withAttributes: codeAttrs)
    }

    private func drawRightAligned(_ string: String, attrs: [NSAttributedString.Key: Any], rightEdge: CGFloat) {
        guard !string.isEmpty else { return }
        let width = (string as NSString).size(withAttributes: attrs).width
        (string as NSString).draw(at: CGPoint(x: rightEdge - width, y: 1), withAttributes: attrs)
    }

    private func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        return s.replacingOccurrences(of: "\t", with: String(repeating: " ", count: Self.tabWidth))
    }

    private func sign(for kind: DiffLineKind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        case .hunkHeader: return ""
        }
    }

    private func backgroundColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: return NSColor.systemGreen.withAlphaComponent(0.16)
        case .deletion: return NSColor.systemRed.withAlphaComponent(0.16)
        case .hunkHeader: return NSColor.systemBlue.withAlphaComponent(0.10)
        case .context: return .clear
        }
    }

    private func textColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .hunkHeader: return .secondaryLabelColor
        default: return .labelColor
        }
    }
}
