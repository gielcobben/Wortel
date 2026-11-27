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
    /// What the left margin is for. A patch is two revisions at once, so it owes
    /// you both sides' numbering and a +/− on every line. A whole file is one
    /// revision, where the second column repeats the first digit for digit and
    /// the sign column is a stripe of blanks — so `.file` draws one number and no
    /// sign, and the code starts where the eye expects a first column.
    var gutter: Gutter = .patch
    /// The source line to put at the top when this view appears — how a preview
    /// window keeps your place across a mode switch. Nil leaves the scroll alone,
    /// which is every other use of this view.
    var anchorLine: Int?
    /// How far past the anchor line's row to scroll, in points: the rest of
    /// the way back to exactly where a reader left a tab.
    var anchorOffset: CGFloat = 0
    /// Reports the source line at the top of the view as it scrolls, and how
    /// far past the top of its row the view is, so the mode you switch to can
    /// open there and a tab you come back to opens exactly there.
    var onTopLine: ((Int, CGFloat) -> Void)?
    /// A line asked for while this view may already be on screen (a
    /// ⌘-clicked `App.swift:42`): selected and scrolled to, once per request,
    /// then handed back through `onRevealed`.
    var reveal: PreviewDocument.LineReveal?
    var onRevealed: ((PreviewDocument.LineReveal) -> Void)?
    /// Reports the line of the selected row (the first, for several), or nil
    /// when nothing is selected.
    var onSelectLine: ((Int?) -> Void)?
    /// Where mark-up finds this table, when it is a preview's (`MarkupViews`).
    var markup: MarkupViews?

    enum Gutter { case patch, file }

    /// Marks this table so the sidebar's SidebarSelectionStyler (which walks the
    /// whole window for NSTableViews) skips it — otherwise it would wire this
    /// diff table's double-click to session-rename and disable its styling.
    static let tableIdentifier = NSUserInterfaceItemIdentifier("WortelDiffTable")

    /// The height of one diff row for a given font size — the same formula the
    /// Coordinator uses in `setStyle`. Lets the History accordion give each
    /// inline diff a frame sized to its content, so small files fit exactly (no
    /// scroller of their own) and only a huge file keeps a bounded one.
    static func rowHeight(forFontSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) + 3
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // Unconditionally, not via `setStyle`: that early-returns when nothing
        // *changed*, and at birth nothing has — the coordinator's initial
        // charWidth and rowHeight are placeholders, not measurements. Letting it
        // skip here left the inspector's 12pt diff on rowHeight 16 where the font
        // wants 18, which clips every descender in the pane.
        context.coordinator.applyStyle(fontSize: fontSize, gutter: gutter)

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
        // …and scroll changes, which is what reports the top line.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeResize(of: scroll)
        register(table, with: context.coordinator)
        return scroll
    }

    /// Tell mark-up which table is the file's now. A tab that comes back
    /// from behind others has a new one, and the marks have to find it.
    private func register(_ table: NSTableView, with coordinator: Coordinator) {
        markup?.sign(table, rowKey: { [weak coordinator] row in coordinator?.key(ofRow: row) })
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The table measures its row height, gutter and column width from the
        // font — once, in `makeNSView`. So a font size arriving later (⌘+/⌘− in
        // a preview window) has to be adopted here, or it changes a number in
        // the model and nothing on screen moves, which reads as a dead menu item.
        let resized = context.coordinator.setStyle(fontSize: fontSize, gutter: gutter)
        context.coordinator.onTopLine = onTopLine
        context.coordinator.onSelectLine = onSelectLine
        // A preview tab kept built behind the one in front is disabled, and
        // it mustn't keep the keyboard: ⌘C would copy lines nobody can see.
        if !context.environment.isEnabled, let table = scroll.documentView,
           let window = table.window, window.firstResponder === table {
            window.makeFirstResponder(nil)
        }
        let result = context.coordinator.update(lines: lines, highlights: highlights)
        guard let table = scroll.documentView as? NSTableView else { return }
        register(table, with: context.coordinator)
        defer {
            // Last, so it wins over the scroll-to-top a new file otherwise gets:
            // arriving in a mode with a place to be is not arriving at a new file.
            context.coordinator.applyAnchor(anchorLine, offset: anchorOffset, in: table, scroll: scroll)
            if let reveal, context.coordinator.reveal(reveal, in: table, scroll: scroll) {
                // After this update: the document is observed, and changing it
                // while SwiftUI is updating this view is a change it warns about.
                DispatchQueue.main.async { onRevealed?(reveal) }
            }
        }
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
        // The rows are other rows, or another size: marks find theirs again.
        if result.scrollToTop || resized { markup?.changed() }
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
        /// Placeholders until `applyStyle` measures the real font — see
        /// `makeNSView`, which is why that call is unconditional.
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var charWidth: CGFloat = 7
        private var gutter: Gutter = .patch
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
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @objc private func viewportResized() { applyColumnWidth() }

        /// Report where the reader is, in source lines.
        @objc private func scrolled() {
            guard let onTopLine, let table, let scroll, !lines.isEmpty else { return }
            let visible = scroll.documentVisibleRect
            let row = table.rows(in: visible).location
            guard row >= 0, row < lines.count else { return }
            onTopLine(sourceLine(atRow: row), visible.minY - table.rect(ofRow: row).minY)
        }

        var onTopLine: ((Int, CGFloat) -> Void)?
        private var anchored = false

        /// What a row holds, for a mark to know its line by: the text and
        /// which side of a diff it is on. Not its number, which changes for
        /// every line under an insertion.
        func key(ofRow row: Int) -> Int? {
            guard lines.indices.contains(row) else { return nil }
            var hasher = Hasher()
            hasher.combine(lines[row].text)
            hasher.combine(lines[row].oldLine == nil)
            hasher.combine(lines[row].newLine == nil)
            return hasher.finalize()
        }

        /// A row's line in the file. Both sides carry it: for a whole file the
        /// two agree, and in a patch the new side is the one that still exists.
        private func sourceLine(atRow row: Int) -> Int {
            lines[row].newLine ?? lines[row].oldLine ?? row + 1
        }

        /// The first row at or after `target`. A diff doesn't contain every line
        /// of the file, so "the line you were on" is often one that was never
        /// shown — landing just after it is the honest answer.
        private func row(forSourceLine target: Int) -> Int? {
            var last: Int?
            for (index, line) in lines.enumerated() {
                guard let number = line.newLine ?? line.oldLine else { continue }
                if number >= target { return index }
                last = index
            }
            return last
        }

        /// Put `line` at the top, once per view — the content arrives after the
        /// anchor does, so this is driven by both.
        func applyAnchor(_ line: Int?, offset: CGFloat, in table: NSTableView, scroll: NSScrollView) {
            // Not while the content is still empty: the anchor arrives with the
            // mode switch, the lines a beat later, and this is what makes the
            // first update that *has* rows the one that scrolls.
            guard let line, !lines.isEmpty else { return }
            // Exactly once per view, which is what arriving is. Re-applying on
            // later reloads would drag the reader back to where they arrived
            // every time the highlighter lands, and a preview tab kept built
            // behind another is handed its own place again whenever its tab
            // redraws: in a diff, where a deleted row's line maps back to the
            // row after it, that moved a reader who was sitting still.
            guard !anchored else { return }
            anchored = true
            guard let row = row(forSourceLine: line), row < table.numberOfRows else { return }
            // Within the row, and only the row the place was measured in: a
            // line that maps to another row (a diff's deleted one), or rows
            // made shorter by ⌘− since, would put the offset rows away.
            let within = sourceLine(atRow: row) == line ? min(max(offset, 0), rowHeight - 1) : 0
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                                                  y: table.rect(ofRow: row).minY + within))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// The single column spans at least the full viewport so each row's
        /// background tint fills the panel edge-to-edge; when the content is
        /// wider it stays content-width and the horizontal scroller appears.
        func applyColumnWidth() {
            guard let table else { return }
            let viewport = scroll?.contentView.bounds.width ?? 0
            table.tableColumns.first?.width = max(columnWidth, viewport)
        }

        /// Adopt a size and a gutter style, reporting whether either actually
        /// differs — the caller only pays for a reload when it does. Everything
        /// geometric follows: the character width and row height are recomputed
        /// here, the gutter and column widths in `recomputeGeometry` on the
        /// update that comes next.
        func setStyle(fontSize: CGFloat, gutter: Gutter) -> Bool {
            guard fontSize != font.pointSize || gutter != self.gutter else { return false }
            applyStyle(fontSize: fontSize, gutter: gutter)
            return true
        }

        func applyStyle(fontSize: CGFloat, gutter: Gutter) {
            self.gutter = gutter
            font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
            geometryIsStale = true
        }

        /// Whether the gutter and column widths still describe what is on
        /// screen. Set by a style change; cleared by `recomputeGeometry`. See
        /// the note there for why this is not simply recomputed every time.
        private var geometryIsStale = true

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

        var onSelectLine: ((Int?) -> Void)?

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let onSelectLine, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRowIndexes.first
            onSelectLine(row.flatMap { $0 < lines.count ? fileLine(atRow: $0) : nil })
        }

        /// A row's line in the file as it is now, which is the file an editor
        /// opens: a deleted row has only the old one, so it takes the next
        /// row that exists now (where the deletion was), else the last.
        private func fileLine(atRow row: Int) -> Int? {
            if let line = lines[row...].lazy.compactMap(\.newLine).first { return line }
            return lines[..<row].reversed().lazy.compactMap(\.newLine).first
        }

        /// The last request shown, so an update for anything else (the
        /// highlighter landing) doesn't show it again.
        private var revealed: PreviewDocument.LineReveal?

        /// Select the row for a requested line and put it a third of the way
        /// down, where the eye lands, with what leads up to it above. True when
        /// it was shown, false while there are no rows to show it in yet.
        func reveal(_ request: PreviewDocument.LineReveal, in table: NSTableView,
                    scroll: NSScrollView) -> Bool {
            guard request != revealed else { return false }
            guard !lines.isEmpty, let row = row(forSourceLine: request.line),
                  row < table.numberOfRows else { return false }
            revealed = request
            // The anchor is this request too; it mustn't be applied again over it.
            anchored = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let viewport = scroll.contentView.bounds.height
            let top = max(table.rect(ofRow: row).minY - viewport / 3, 0)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }

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
            // Count alone, deliberately: `highlights` only ever goes from empty
            // to filled for a given line set (the model publishes the parsed
            // diff first and the spans a beat later), so a changed count is the
            // arrival. A deep compare would be O(lines) on every re-render,
            // which is exactly the cost the guard below exists to avoid.
            let highlightsChanged = highlights.count != self.highlights.count
            self.lines = lines
            self.highlights = highlights
            // Only when it can have moved. This walks every line's *characters*
            // to find the widest row, and `updateNSView` runs on any observable
            // change — in the History accordion that means every mounted diff
            // re-renders whenever any sibling file finishes loading. The row
            // reload is already gated for that reason; this has to be too, or
            // Expand All on a large commit pays a full character walk of every
            // open diff per file that lands.
            if linesChanged || geometryIsStale {
                recomputeGeometry()
                geometryIsStale = false
            }
            return (linesChanged || highlightsChanged, linesChanged)
        }

        private func recomputeGeometry() {
            var maxNo = 1
            var maxChars = 0
            for line in lines {
                maxNo = max(maxNo, line.oldLine ?? 0, line.newLine ?? 0)
                // +1 for the sign column; tabs expand to DiffLineCellView.tabWidth.
                let expanded = line.text.reduce(0) { $0 + ($1 == "\t" ? DiffLineCellView.tabWidth : 1) }
                maxChars = max(maxChars, expanded + (gutter == .patch ? 1 : 0))
            }
            let digits = max(2, String(maxNo).count)
            let numColumn = CGFloat(digits) * charWidth + 10
            gutterWidth = (gutter == .patch ? numColumn * 2 : numColumn) + 6
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
            cell.gutter = gutter
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
    var gutter = DiffView.Gutter.patch

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
        // No sign column in a file: every line is context, so it draws a
        // column of spaces that only pushes the code off its own margin.
        let signText = gutter == .patch ? sign(for: line.kind) : ""
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
        // A step brighter on an added or removed line: the tint under it ate
        // most of tertiary's contrast. Context keeps the quiet colour, so a
        // whole file's gutter doesn't get louder.
        let changed = line.kind == .addition || line.kind == .deletion
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: changed ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ]

        if line.kind != .hunkHeader {
            switch gutter {
            case .patch:
                drawRightAligned(line.oldLine.map(String.init) ?? "",
                                 attrs: numberAttrs, rightEdge: numColumn - 2)
                drawRightAligned(line.newLine.map(String.init) ?? "",
                                 attrs: numberAttrs, rightEdge: numColumn * 2 - 2)
            case .file:
                drawRightAligned((line.newLine ?? line.oldLine).map(String.init) ?? "",
                                 attrs: numberAttrs, rightEdge: gutterWidth - 8)
            }
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
