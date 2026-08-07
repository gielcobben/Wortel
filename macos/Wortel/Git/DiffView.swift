import AppKit
import SwiftUI

/// Renders a unified diff as an `NSTableView` — one row per line — so even a
/// several-thousand-line diff scrolls smoothly (the table only realizes visible
/// rows). Each row is a single custom view that draws its own tint, gutter line
/// numbers, and monospaced code, with no per-row Auto Layout. This is the same
/// "drop to AppKit where SwiftUI would choke" move the rest of the shell makes.
struct DiffView: NSViewRepresentable {
    let lines: [DiffLine]
    /// Syntax-highlight spans by `DiffLine.id`, filled in asynchronously (see
    /// `DiffResult.highlights`). Empty renders as plain monospaced text.
    var highlights: [Int: [HighlightSpan]] = [:]
    /// A row to select and scroll into view — how the preview window's find bar
    /// says "this one". Nil leaves the reader's selection and scroll alone,
    /// which is every other use of this view.
    var focusedLine: Int?
    let fontSize: CGFloat

    /// Marks this table so the sidebar's SidebarSelectionStyler (which walks the
    /// whole window for NSTableViews) skips it — otherwise it would wire this
    /// diff table's double-click to session-rename and disable its styling.
    static let tableIdentifier = NSUserInterfaceItemIdentifier("WortelDiffTable")

    /// The height of one diff row for a given font size — the same formula the
    /// Coordinator uses in `configure`. Lets the History accordion give each
    /// inline diff a frame sized to its content, so small files fit exactly (no
    /// scroller of their own) and only a huge file keeps a bounded one.
    static func rowHeight(forFontSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) + 3
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        context.coordinator.configure(font: font)

        let table = DiffTableView()
        table.identifier = Self.tableIdentifier
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        // Rows are selectable so lines of code can be copied out (⌘C or the
        // right-click menu) — the "agent changed this, grab those three lines"
        // path. Selection is line-granular: the rows are hand-drawn, so there
        // is no character-level text machinery to hook into, and whole lines
        // are what pasting into a terminal wants anyway.
        table.allowsMultipleSelection = true
        table.selectionText = { [weak coordinator = context.coordinator] rows in
            coordinator?.selectionText(for: rows) ?? ""
        }
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.rowHeight = context.coordinator.rowHeight
        table.intercellSpacing = .zero
        table.allowsColumnResizing = false
        // `.plain`, not the default `.automatic`: inside an inspector the
        // automatic style adds leading/trailing cell insets, which left the row
        // tints floating off the pane's edges. Plain runs them wall to wall.
        table.style = .plain

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
        // No system-added insets: the pane runs the diff under the titlebar and
        // as an inspector item, either of which would otherwise push a top/side
        // margin in. The diff supplies its own gutter, so it wants none here.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // Follow live width changes so the row tints keep filling the panel as
        // it (or the window) is resized.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.observeResize(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The table measures its row height, gutter and column width from the
        // font — once, in `makeNSView`. So a font size arriving later (⌘+/⌘− in
        // a preview window) has to be adopted here, or it changes a number in
        // the model and nothing on screen moves, which reads as a dead menu item.
        let resized = context.coordinator.setFontSize(fontSize)
        let result = context.coordinator.update(lines: lines, highlights: highlights)
        guard let table = scroll.documentView as? NSTableView else { return }
        // Always re-fit the column to the viewport (the panel may have resized).
        context.coordinator.applyColumnWidth()
        // But only reload rows when this table's own data changed. In the History
        // accordion, any file's diff loading re-renders every mounted DiffView;
        // without this guard each full-height table (every row realized) would
        // reloadData on every sibling's load — O(files²) on Expand All.
        context.coordinator.focus(focusedLine, in: table)
        guard result.reload || resized else { return }
        // The row being read, noted before the rows change height underneath it:
        // the scroll offset is in points, so resizing the type without this walks
        // the reader somewhere else in the file on every press of ⌘+.
        let anchor = resized ? table.rows(in: scroll.documentVisibleRect).location : -1
        if resized { table.rowHeight = context.coordinator.rowHeight }
        table.reloadData()
        if anchor > 0, anchor < table.numberOfRows {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                                                  y: table.rect(ofRow: anchor).minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        context.coordinator.focus(focusedLine, in: table, force: true)
        if result.scrollToTop {
            // New file selected — jump back to the top, and drop the old file's
            // selection (reloadData keeps row indexes selected, which would
            // silently select unrelated lines of the new file).
            table.deselectAll(nil)
            table.scroll(.zero)
            scroll.contentView.scroll(to: .zero)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("diff")
        private static let cellID = NSUserInterfaceItemIdentifier("diffCell")
        private static let rowID = NSUserInterfaceItemIdentifier("diffRow")

        private(set) var lines: [DiffLine] = []
        private var highlights: [Int: [HighlightSpan]] = [:]
        private let theme = DiffSyntaxTheme()
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

        /// Adopt a new size, reporting whether it actually differs — the caller
        /// only pays for a reload when it does. Everything geometric follows:
        /// `configure` recomputes the character width and row height, and the
        /// column width falls out of `recomputeGeometry` on the next update.
        func setFontSize(_ size: CGFloat) -> Bool {
            guard size != font.pointSize else { return false }
            configure(font: .monospacedSystemFont(ofSize: size, weight: .regular))
            return true
        }

        func configure(font: NSFont) {
            self.font = font
            charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
        }

        /// Reports whether the table needs a reload, and whether it should scroll
        /// back to the top. A changed line set (a new file) means both. Highlights
        /// arriving a beat later for the *same* lines means reload only — recolour
        /// in place, leaving the reader's scroll alone. Nothing changed means
        /// neither, so a re-render caused by a *sibling* file loading doesn't
        /// reload this (full-height, fully-realized) table.
        /// Move the selection to a row and scroll it into view. Only on an
        /// actual change, or every unrelated re-render would yank the reader
        /// back to the last match.
        private var focusedLine: Int?

        func focus(_ line: Int?, in table: NSTableView, force: Bool = false) {
            guard force || line != focusedLine else { return }
            focusedLine = line
            guard let line, line >= 0, line < table.numberOfRows else { return }
            table.selectRowIndexes(IndexSet(integer: line), byExtendingSelection: false)
            table.scrollRowToVisible(line)
        }

        func update(
            lines: [DiffLine], highlights: [Int: [HighlightSpan]]
        ) -> (reload: Bool, scrollToTop: Bool) {
            let linesChanged = lines.count != self.lines.count
                || zip(lines, self.lines).contains { $0.id != $1.id || $0.text != $1.text }
            let highlightsChanged = highlights.count != self.highlights.count
            self.lines = lines
            self.highlights = highlights
            recomputeGeometry()
            return (linesChanged || highlightsChanged, linesChanged)
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

        /// The pasteboard text for a set of selected rows: the raw line text
        /// joined by newlines — no gutter numbers, no +/- signs — so what's
        /// pasted into a terminal is code, not diff decoration.
        func selectionText(for rows: IndexSet) -> String {
            rows.compactMap { lines.indices.contains($0) ? lines[$0].text : nil }
                .joined(separator: "\n")
        }

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: Self.rowID, owner: self) as? DiffRowView
                ?? DiffRowView()
            rowView.identifier = Self.rowID
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? DiffLineCellView
                ?? DiffLineCellView(identifier: Self.cellID)
            cell.font = font
            cell.charWidth = charWidth
            cell.gutterWidth = gutterWidth
            cell.theme = theme
            cell.configure(line: lines[row], spans: highlights[lines[row].id] ?? [])
            return cell
        }
    }
}

/// The diff's table, subclassed for copying: `copy:` is dispatched nil-target
/// from the Edit menu, so implementing it here is all ⌘C needs once the table
/// is first responder (which clicking a row makes it). Right-click offers the
/// same copy without touching keyboard focus.
final class DiffTableView: NSTableView {
    /// Supplies the pasteboard text for the selected rows — set by `DiffView`
    /// to the Coordinator's line store, which owns what the rows mean.
    var selectionText: ((IndexSet) -> String)?

    @objc func copy(_ sender: Any?) {
        guard let text = selectionText?(selectedRowIndexes), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Right-click: pull the clicked row into the selection if it's outside it
    /// (the native table convention), then offer Copy.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Copy") { [weak self] in self?.copy(nil) })
        return menu
    }
}

/// Selection stays the unemphasized gray even while the table has keyboard
/// focus: the row tints (green/red at low alpha) blend over the selection
/// fill, and the label-colored code stays readable where the emphasized
/// accent blue would fight both.
final class DiffRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// One diff line, drawn by hand: background tint, two right-aligned line-number
/// columns in the gutter, then the sign + code in the document's monospaced
/// font. Flipped so y grows downward like text.
final class DiffLineCellView: NSView {
    static let tabWidth = 4

    private(set) var line: DiffLine?
    private var spans: [HighlightSpan] = []
    var theme = DiffSyntaxTheme()
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { rebuild() } }
    var charWidth: CGFloat = 7
    var gutterWidth: CGFloat = 60

    /// The code column — sign + syntax-coloured text, tabs expanded — built once
    /// per (line, spans) and redrawn from cache on every scroll/resize. Dynamic
    /// theme colours re-resolve for light/dark automatically at draw time.
    private var codeString: NSAttributedString?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(line: DiffLine, spans: [HighlightSpan]) {
        self.line = line
        self.spans = spans
        rebuild()
        needsDisplay = true
    }

    /// Build the code column: text in the line's base colour, each highlight span
    /// recoloured, THEN tabs expanded and the +/-/space sign prepended — in that
    /// order, so span ranges (computed over the raw line text) stay valid while
    /// the later edits shift positions with their attribute runs intact.
    private func rebuild() {
        guard let line else { codeString = nil; return }
        let base = textColor(for: line.kind)
        let s = NSMutableAttributedString(
            string: line.text, attributes: [.font: font, .foregroundColor: base])
        if line.kind != .hunkHeader {
            let length = s.length
            for span in spans where NSMaxRange(span.range) <= length {
                s.addAttribute(.foregroundColor, value: theme.color(for: span.token), range: span.range)
            }
        }
        s.mutableString.replaceOccurrences(
            of: "\t", with: String(repeating: " ", count: Self.tabWidth),
            options: [], range: NSRange(location: 0, length: s.length))
        let signText = sign(for: line.kind)
        if !signText.isEmpty {
            s.insert(NSAttributedString(
                string: signText, attributes: [.font: font, .foregroundColor: base]), at: 0)
        }
        codeString = s
    }

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

        let x = line.kind == .hunkHeader ? 8 : gutterWidth + 6
        codeString?.draw(at: CGPoint(x: x, y: 1))
    }

    private func drawRightAligned(_ string: String, attrs: [NSAttributedString.Key: Any], rightEdge: CGFloat) {
        guard !string.isEmpty else { return }
        let width = (string as NSString).size(withAttributes: attrs).width
        (string as NSString).draw(at: CGPoint(x: rightEdge - width, y: 1), withAttributes: attrs)
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

/// The GitHub syntax palette (Primer "default" light + dark), so the diff reads
/// like a GitHub code view. Each colour is appearance-aware — the exact GitHub
/// light hex in light mode, the dark hex in dark mode — resolved per draw.
/// Plain identifiers and punctuation stay at the default text colour, as GitHub
/// leaves them.
struct DiffSyntaxTheme {
    func color(for token: HighlightToken) -> NSColor {
        switch token {
        case .keyword, .operator, .label:  return Self.red      // keywords, operators
        case .function, .constructor:      return Self.purple   // function / method names
        case .type, .module:               return Self.orange   // types, namespaces
        case .string, .escape:             return Self.blueLt   // string literals
        case .comment:                     return Self.gray
        case .number, .constant,
             .property, .attribute:        return Self.blue     // constants, numbers, json/css keys, attrs
        case .tag:                         return Self.green     // html/xml tags
        case .variable, .punctuation:      return .labelColor    // GitHub leaves these as plain text
        }
    }

    // GitHub Primer default: light hex / dark hex.
    private static let red    = dynamic(light: 0xCF222E, dark: 0xFF7B72)
    private static let purple = dynamic(light: 0x8250DF, dark: 0xD2A8FF)
    private static let orange = dynamic(light: 0x953800, dark: 0xFFA657)
    private static let blue   = dynamic(light: 0x0550AE, dark: 0x79C0FF)
    private static let blueLt = dynamic(light: 0x0A3069, dark: 0xA5D6FF)
    private static let green  = dynamic(light: 0x116329, dark: 0x7EE787)
    private static let gray   = dynamic(light: 0x6E7781, dark: 0x8B949E)

    /// An NSColor that resolves to the `light` hex in light appearance and the
    /// `dark` hex in dark appearance, evaluated per draw.
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
