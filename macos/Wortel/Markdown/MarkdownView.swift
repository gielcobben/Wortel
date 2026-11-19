import AppKit
import SwiftUI

/// Renders `[MarkdownBlock]` natively — one styled SwiftUI view per block, with
/// inline markdown (bold/italic/code/links) handled by Foundation's
/// `AttributedString` and fenced code coloured by tree-sitter (see
/// `CodeBlockView`). No WebView, no markdown library.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// Multiplies the whole type scale — text, headings, code, and the gaps
    /// between blocks — so ⌘+/⌘− move a rendered document the way they move
    /// source. A ratio rather than a point size because a document has a *scale*,
    /// not one font: scaling it keeps the proportions the design chose. 1 is the
    /// designed size.
    var scale: CGFloat = 1
    /// Everything is selected (⌘A), drawn as one wash over the column. The
    /// document is a stack of separate `Text` views, so there is no single
    /// selection to tint — but "all of this" is what was asked for, and it reads
    /// as that.
    var isSelected = false
    /// The source line to open at — how a mode switch, or coming back to a
    /// tab, keeps your place.
    var anchorLine: Int?
    /// How far past the top of the anchor's block to land, in points: the rest
    /// of the way back to exactly where a reader left a tab.
    var anchorOffset: CGFloat = 0
    /// Reports the source line of the block at the top of the view, and how far
    /// past that block's top the view is scrolled, so the mode you switch to
    /// can open there and a tab you come back to opens exactly there.
    var onTopLine: ((Int, CGFloat) -> Void)?
    /// A line asked for while this view may already be on screen: the block
    /// holding it goes to the top, once per request, then it is handed back.
    var reveal: PreviewDocument.LineReveal?
    var onRevealed: ((PreviewDocument.LineReveal) -> Void)?
    /// The file being rendered. A document's links are mostly relative to the
    /// directory it sits in, so without this there is nothing for `../CLAUDE.md`
    /// to be relative *to* and those links go nowhere (see `MarkdownLinkTarget`).
    var baseURL: URL?
    /// Opens a file this document links to, in a preview window of its own.
    /// Routed out rather than done here: which view a file opens on, and which
    /// diff it gets, is one decision made in one place for every opener in the
    /// app.
    var onOpenFile: ((URL) -> Void)?

    /// Where each visible block sits, keyed by block id. Only the realized ones
    /// report — the stack is lazy — so this is a handful of values per frame
    /// rather than one per block in the file.
    private struct BlockOffsets: PreferenceKey {
        static let defaultValue: [Int: CGFloat] = [:]
        static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
            value.merge(nextValue()) { first, _ in first }
        }
    }

    private static let space = "markdown"

    /// The anchor has been applied to a document with blocks in it. Once per
    /// view, as `DiffView` does: a file rewritten under the reader changes the
    /// block count too, and going back to the anchor then would drag them to
    /// wherever they arrived.
    @State private var anchored = false
    /// Where a block should sit once `scrollTo` has brought it to the top: the
    /// offset, which `ScrollViewProxy` has no way to say. Applied by the first
    /// report that has the block at the top, so it measures from where the
    /// block actually landed, and not from a pass before the scroll took.
    @State private var landing: Landing?
    @State private var scrollView = EnclosingScrollView()

    private struct Landing: Equatable {
        let id = UUID()
        let block: Int
        /// The block's top relative to the viewport's: minus the offset.
        let top: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            scroller
                // Every link in the document comes through here. Without it the
                // system gets them, and a relative one — which is most of what a
                // README links to — arrives with no scheme and comes back as an
                // error dialog. See `MarkdownLinkTarget`.
                .environment(\.openURL, OpenURLAction { follow($0, with: proxy) })
                .onAppear {
                    scroll(to: anchorLine, with: proxy)
                    show(reveal, with: proxy)
                }
                // The document arrives after the view does, so the anchor has to
                // be applied again once there is something to scroll.
                .onChange(of: blocks.count) { _, _ in
                    if !anchored { scroll(to: anchorLine, with: proxy) }
                    show(reveal, with: proxy)
                }
                .onChange(of: reveal) { _, request in show(request, with: proxy) }
        }
    }

    /// Follow a clicked link: out to the browser, into a preview window of its
    /// own, to Finder, or to a heading in this document.
    private func follow(_ link: URL, with proxy: ScrollViewProxy) -> OpenURLAction.Result {
        let target = MarkdownLinkTarget.resolve(link, in: baseURL)
        // The one destination that never leaves this document, and the only one
        // that needs the scroller.
        if case .heading(let anchor) = target {
            guard let id = MarkdownAnchor.blockID(for: anchor, in: blocks) else { return .discarded }
            proxy.scrollTo(id, anchor: .top)
            return .handled
        }
        // A web link goes through the system action rather than through
        // `NSWorkspace` here, so SwiftUI's own handling (and anything a host
        // installs above this view) still gets its say.
        if case .web(let url) = target { return .systemAction(url) }
        // Otherwise: opened, or dropped on purpose. A link to a file that isn't
        // there and a scheme we don't launch both do nothing, which is honest —
        // an error dialog about a file the reader never asked for is not.
        return open(target) ? .handled : .discarded
    }

    /// Act on a resolved target that isn't an anchor. Returns whether it did.
    @discardableResult
    private func open(_ target: MarkdownLinkTarget) -> Bool {
        switch target {
        case .file(let url):
            onOpenFile?(url)
            return true
        case .package(let url):
            // Shown, not opened: opening an app is running it.
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        case .folder(let url), .web(let url):
            // A folder is the one destination this app has no view for, and
            // Finder is what "open this folder" means everywhere else on the
            // Mac. The alternative — a click that does nothing — is the failure
            // this whole type exists to avoid.
            NSWorkspace.shared.open(url)
            return true
        case .heading, .none:
            return false
        }
    }

    /// Bring the block holding a requested line to the top. Not before there
    /// are blocks: the request stays with the document until then.
    private func show(_ request: PreviewDocument.LineReveal?, with proxy: ScrollViewProxy) {
        guard let request, !blocks.isEmpty,
              let target = blocks.last(where: { $0.line <= request.line }) ?? blocks.first
        else { return }
        anchored = true
        landing = nil
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: .top)
            onRevealed?(request)
        }
    }

    /// The block to land on for a source line: the last one that starts at or
    /// before it, since a line inside a paragraph belongs to that paragraph.
    private func scroll(to line: Int?, with proxy: ScrollViewProxy) {
        if !blocks.isEmpty { anchored = true }
        let offset = anchorOffset
        guard let line, line > 1 || offset != 0,
              let target = blocks.last(where: { $0.line <= line }) ?? blocks.first
        else { return }
        // A turn later: with a lazy stack the rows for that id may not exist yet
        // on the pass that builds the view.
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: .top)
            guard offset != 0 else { return }
            let next = Landing(block: target.id, top: -offset)
            landing = next
            // A landing is for arriving. One still waiting a while later (the
            // block never reached the top: the end of the document, where the
            // scroll stops short and the offset means nothing anyway) would
            // otherwise fire when the reader scrolls there themselves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if landing == next { landing = nil }
            }
        }
    }

    /// Finish a landing: the block is on screen at `current`, so scroll the
    /// rest of the way by hand. A SwiftUI scroll view is an `NSScrollView` on
    /// the Mac; without one this stays at the block's top, which is where the
    /// line alone already put it.
    private func land(_ landing: Landing, from current: CGFloat) {
        guard let scroll = scrollView.view?.enclosingScrollView,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let delta = current - landing.top
        guard abs(delta) >= 0.5 else { return }
        var bounds = clip.bounds
        bounds.origin.y += document.isFlipped ? delta : -delta
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private var scroller: some View {
        ScrollView {
            // Spacing is per-block (see `topGap`) rather than a uniform stack
            // gap: consecutive list items sit tight, headings get air above, and
            // prose keeps a comfortable rhythm — the difference between "rendered"
            // and "typeset".
            LazyVStack(alignment: .center, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block)
                        // The measure is applied per block, not to the stack, so
                        // a block that benefits from width can opt out of it.
                        .frame(maxWidth: widthLimit(for: block.kind), alignment: .leading)
                        .padding(.top, gap(
                            previous: index > 0 ? blocks[index - 1].kind : nil,
                            current: block))
                        .id(block.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BlockOffsets.self,
                                    value: [block.id: geometry
                                        .frame(in: .named(Self.space)).minY])
                            }
                        }
                }
            }
            .background(EnclosingScrollView.Marker(box: scrollView))
            .lineSpacing(lineSpacing)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            // **Not selectable, deliberately.** Text selection puts an I-beam
            // over the entire document, links included, so a link looks like text
            // rather than like something to click — and SwiftUI gives no way to
            // vary the cursor per run. Without it the platform's own cursors come
            // back: a pointing hand over links, an arrow over prose. The trade is
            // per-paragraph dragging, which was never the way to copy out of here
            // anyway: ⌘2 shows the same file in a view built for selecting, and
            // ⌘A still marks the whole document for ⌘C.
            // Select All, for the one mode that can't do it itself. SwiftUI
            // selects *within* one `Text`, so a drag can't cross a heading and
            // ⌘A has nothing to act on — see `PreviewWindowController.selectAll`,
            // which pairs this with a Copy of the whole document.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.25))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(BlockOffsets.self) { offsets in
            reportTopBlock(offsets)
        }
    }

    /// The block at the top of the viewport: the last one that has scrolled past
    /// it, or the first one still below if none has.
    private func reportTopBlock(_ offsets: [Int: CGFloat]) {
        if let landing, let current = offsets[landing.block], abs(current) < 1 {
            self.landing = nil
            land(landing, from: current)
        }
        guard let onTopLine, !offsets.isEmpty else { return }
        let above = offsets.filter { $0.value <= 8 }.max { $0.value < $1.value }?.key
        let below = offsets.min { $0.value < $1.value }?.key
        // Ids are positions (see `testBlockOrderAndSequentialIDs`), so this is a
        // subscript rather than a search — it runs on every scroll frame.
        guard let id = above ?? below, blocks.indices.contains(id),
              let top = offsets[id] else { return }
        onTopLine(blocks[id].line, -top)
    }

    /// The reading measure, in characters, measured in the actual font rather
    /// than guessed at — so it holds at every size ⌘+ can reach.
    ///
    /// The researched band for continuous reading is 45–75 characters
    /// (Bringhurst's rule, on Tinker & Paterson's eye-movement work), with ~66
    /// the usual optimum. This sits deliberately past it: that band is for prose
    /// read start to finish, and these documents are technical — long
    /// identifiers, inline paths, and wide code blocks that a narrow measure
    /// wraps into nonsense. Set with the eyes rather than the literature, which
    /// is the right way round when the two disagree about a specific document.
    private static let charactersPerLine: CGFloat = 82

    /// 160% of the type size — but SwiftUI's `lineSpacing` is the gap it *adds
    /// between* lines, not the total, so the font's own line height has to come
    /// off first. Hard-coding a gap instead (it was 4) silently changes the ratio
    /// every time the size does, which is exactly what ⌘+ does.
    private var lineSpacing: CGFloat {
        Self.lineSpacing(for: NSFont.systemFont(ofSize: bodySize), size: bodySize, ratio: 1.5)
    }

    /// The gap that lands a line *advance* on a whole point.
    ///
    /// Rounding the gap would be the obvious move and the wrong one: what has to
    /// sit on the pixel grid is the distance from one baseline to the next, and
    /// that's the font's own line height plus the gap. Quantise the total, then
    /// solve for the gap — the ratio lands within a hundredth either way, and
    /// every baseline in a long document stays sharp instead of drifting half a
    /// pixel further off with each line.
    static func lineSpacing(for font: NSFont, size: CGFloat, ratio: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender + font.leading
        return max(0, (size * ratio).rounded() - natural)
    }

    /// Everything stops at the measure — including tables and code, which were
    /// briefly allowed past it. A block wider than the column reads as a break in
    /// the page rather than as extra room, and the column *is* the page.
    private func widthLimit(for kind: MarkdownBlock.Kind) -> CGFloat { measure }

    private var measure: CGFloat {
        let sample = "the quick brown fox jumps over the lazy dog "
        let width = (sample as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: bodySize)]).width
        return (width / CGFloat(sample.count) * Self.charactersPerLine).rounded()
    }

    /// The space above a block, given what precedes it. First block: none.
    /// Consecutive list items: tight. Into a heading: generous, so sections
    /// read as sections. Otherwise a steady paragraph rhythm.
    /// The space above a block, **in multiples of the body size** rather than in
    /// points. Points don't hold: raising the type from 14 to 16 left every gap
    /// where it was, so the whole document tightened up without a single spacing
    /// value changing. Spacing is a property of the type it separates.
    /// GitHub's rhythm, in ems of the body: **1.5 above a heading, 1 above
    /// everything else** — which, since the gap always belongs to the block
    /// below it, makes a heading's space above exactly 1.5× its space below.
    ///
    /// That ratio is the whole of "sections read as sections". A heading is a
    /// label for what follows, so it has to sit closer to its own paragraph than
    /// to the one it just ended; get it the other way round, or even close to
    /// even, and the page reads as an undifferentiated column no matter how large
    /// the headings are. Roomier values were tried first and lost exactly here:
    /// more air everywhere separates nothing, because separation is proportion.
    private static func topGapRatio(
        previous: MarkdownBlock.Kind?, current: MarkdownBlock.Kind
    ) -> CGFloat {
        guard let previous else { return 0 }
        if isListItem(current) {
            return isListItem(previous) ? 0.25 : 1
        }
        switch current {
        case .heading: return 1.5
        case .rule: return 1.5
        default: return 1
        }
    }

    /// Rounded to whole points: a block boundary landing on a half point puts
    /// every baseline below it off the pixel grid.
    private func gap(previous: MarkdownBlock.Kind?, current: MarkdownBlock) -> CGFloat {
        var ratio = Self.topGapRatio(previous: previous, current: current.kind)
        // Two lists in a row are two lists, not one long one — and the only
        // thing that says so is the blank line between them in the source.
        // Without this they run together and a document of short lists reads as
        // a single undifferentiated column of bullets.
        if current.afterBlank, ratio < 1 { ratio = 1 }
        return (ratio * bodySize).rounded()
    }

    private static func isListItem(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .bullet, .ordered, .task: return true
        default: return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            styled(block.text, size: headingSize(level))
                .font(headingFont(level))
                // Headings set tighter than body text: 1.25 against the body's
                // 1.5, the same as GitHub's. Display type needs less air between
                // lines, and a two-line heading should read as one object.
                .lineSpacing(Self.lineSpacing(
                    for: .systemFont(ofSize: headingSize(level), weight: .semibold),
                    size: headingSize(level), ratio: 1.25))
                // A hairline under h1 and h2, as GitHub draws — the clearest
                // section boundary available, and the reason its long READMEs
                // stay navigable. Below h2 it would be noise: those are
                // subsections, and the size difference already says so.
                .padding(.bottom, level <= 2 ? (headingSize(level) * 0.3).rounded() : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if level <= 2 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                    }
                }
                // Body line spacing is set on the whole stack; a 28pt heading
                // that wraps doesn't want it. Display type sets tighter than
                // text — the larger it is, the less air between lines it needs.
                .lineSpacing(0)
        case .paragraph:
            styled(block.text, size: bodySize)
                .font(.system(size: bodySize))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent):
            listRow(marker: "•", text: block.text, indent: indent)
        case .ordered(let indent, let marker):
            listRow(marker: marker, text: block.text, indent: indent)
        case .task(let indent, let checked):
            taskRow(checked: checked, text: block.text, indent: indent)
        case .quote:
            HStack(spacing: bodySize) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: (bodySize * 0.25).rounded())
                styled(block.text, size: bodySize)
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 2)
        case .code(let language):
            CodeBlockView(code: block.text, language: language, scale: scale)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .images(let images):
            imageRow(images)
        }
    }

    /// The pictures on their own line: one screenshot, or a row of badges that
    /// wraps like the text around it.
    private func imageRow(_ images: [MarkdownImage]) -> some View {
        // Baseline-aligned so a row of badges of slightly different heights sits
        // on one line rather than on a ragged edge.
        ImageRowLayout(spacing: (bodySize * 0.4).rounded()) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                MarkdownImageView(image: image,
                                  baseURL: baseURL,
                                  maxWidth: measure,
                                  size: bodySize) { destination in
                    guard let url = URL(string: destination) else { return }
                    open(MarkdownLinkTarget.resolve(url, in: baseURL))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: String, text: String, indent: Int) -> some View {
        // GitHub indents list text by 2em with the marker hanging inside it.
        HStack(alignment: .firstTextBaseline, spacing: (bodySize * 0.45).rounded()) {
            Text(verbatim: marker)
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
                .frame(minWidth: (bodySize * 1.1).rounded(), alignment: .trailing)
            styled(text, size: bodySize)
                .font(.system(size: bodySize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 5)) * bodySize)
    }

    /// A task-list row: a real checkbox glyph (filled + accent when done) and the
    /// item text. Read-only — the preview renders the file, it doesn't edit it.
    private func taskRow(checked: Bool, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: (bodySize * 0.45).rounded()) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: bodySize))
                .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(minWidth: (bodySize * 1.1).rounded(), alignment: .trailing)
            styled(text, size: bodySize)
                .font(.system(size: bodySize))
                .foregroundStyle(checked ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 5)) * 16)
    }

    /// A real bordered table, as GitHub draws one.
    ///
    /// The design question a markdown table asks is how much structure to draw,
    /// and the answer depends on whether cells wrap. Ours do (they used to
    /// scroll away instead), so a row can be three lines tall — and at that point
    /// a header rule alone leaves you guessing which right-hand cell belongs to
    /// which left-hand one. Full borders plus alternating row fills answer it
    /// without the reader having to track across.
    ///
    /// Borders are drawn on each cell's *top and leading* edges only, with the
    /// outer stroke closing the frame. Drawing all four would double every
    /// interior line, which is what `border-collapse: collapse` exists to prevent
    /// in CSS and has to be done by hand here.
    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        // Wrap if it can, scroll if it can't — which is what GitHub does, and
        // the two halves are easy to mistake for one choice. Its CSS reads
        // `width: max-content; max-width: 100%; overflow: auto`: the table asks
        // for its natural width, gets clamped to the column, and its cells wrap
        // to fit. Only content that *cannot* wrap — a URL, a long code span, any
        // unbroken token — overflows, and that's what the scroller is for.
        //
        // So the question isn't how wide the table wants to be, it's how narrow
        // it could ever be: the sum of each column's widest single token, which
        // is CSS's min-content width. Below the measure, wrapping will always
        // find a way and the table fills the column. Above it, no amount of
        // wrapping helps and squeezing anyway would shred every cell into one
        // word per line.
        if minimumWidth(header: header, rows: rows, columns: columns) > measure {
            ScrollView(.horizontal) {
                // A band under the last row for the overlay scroller, which
                // floats on the content rather than beside it.
                tableGrid(header: header, rows: rows, columns: columns)
                    .padding(.bottom, (bodySize * 0.55).rounded())
            }
            // **The frame belongs to the viewport, not to the grid.** Put it on
            // the grid and it scrolls away with the content: the left border
            // slides off, the right one arrives from nowhere, and the rounded
            // corners go with them. On the viewport it stays put and the rows
            // move inside it — which is what "scrolling inside the table" means,
            // and what the box around it is claiming.
            .framedAsTable()
        } else {
            tableGrid(header: header, rows: rows, columns: columns)
                .framedAsTable()
        }
    }

    /// The narrowest this table could ever be laid out: per column, the widest
    /// token that can't be broken, plus its padding.
    private func minimumWidth(header: [String], rows: [[String]], columns: Int) -> CGFloat {
        let prose = NSFont.systemFont(ofSize: bodySize)
        let code = NSFont.monospacedSystemFont(
            ofSize: Self.codeSize(for: bodySize), weight: .regular)
        let padding = (bodySize * 0.8125).rounded() * 2
        var total: CGFloat = 0
        for column in 0..<columns {
            var widest: CGFloat = 0
            for cells in [header] + rows where column < cells.count {
                for token in cells[column].split(separator: " ") {
                    let isCode = token.contains("`")
                    let text = token.replacingOccurrences(of: "`", with: "")
                    widest = max(widest, (text as NSString)
                        .size(withAttributes: [.font: isCode ? code : prose]).width)
                }
            }
            total += widest + padding
        }
        return total
    }

    private func tableGrid(header: [String], rows: [[String]], columns: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    tableCell(column < header.count ? header[column] : "",
                              weight: .semibold, row: 0, column: column)
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        tableCell(column < rows[row].count ? rows[row][column] : "",
                                  weight: .regular, row: row + 1, column: column)
                    }
                }
            }
        }
    }

    /// GitHub's 6px/13px cell padding, in ems. `fixedSize(horizontal: false, …)`
    /// is what lets a cell wrap rather than demand its full single-line width and
    /// push the columns beside it off the page.
    private func tableCell(
        _ text: String, weight: Font.Weight, row: Int, column: Int
    ) -> some View {
        styled(text, size: bodySize)
            .font(.system(size: bodySize, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, (bodySize * 0.375).rounded())
            .padding(.horizontal, (bodySize * 0.8125).rounded())
            // Fill the row's height, not just this cell's content. A Grid sizes
            // each cell to itself, so an empty or one-line cell beside a wrapped
            // one left its fill short — the white band under the last columns of
            // a row with a missing cell.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Every other row filled, counting the header as the first — so the
            // first row of data is shaded and the eye has a stripe to follow.
            .background(row.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
            .overlay(alignment: .top) {
                if row > 0 {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
            }
            .overlay(alignment: .leading) {
                if column > 0 {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                }
            }
    }

    /// Base reading size for body text; the rest of the type scale derives from
    /// it. Larger than the system `.body` (~13pt) — this is a document you read,
    /// not chrome.
    static let baseBodySize: CGFloat = 16
    /// Monospace against prose. See the note in `inline`.
    static let codeRatio: CGFloat = 0.85

    /// The body size, on a whole point.
    ///
    /// Only the *body* is snapped. The ratios derived from it — `0.85` for code,
    /// `0.85`–`2` for headings — are left exact, so code lands on GitHub's 13.6pt
    /// rather than on a rounded 13 or 14. What has to sit on the pixel grid is
    /// the line advance, not the type size, and that is quantised separately in
    /// `lineSpacing(for:size:ratio:)` — so baselines stay sharp even where the
    /// size that produced them is fractional.
    static func snapped(_ size: CGFloat) -> CGFloat { max(1, size.rounded(.down)) }

    /// The size code is set at, wherever it appears: a block, an inline chip, or
    /// the measurement that decides whether a table has to scroll. One function,
    /// so those three can't drift apart.
    static func codeSize(for size: CGFloat) -> CGFloat { size * codeRatio }

    /// The reading size after `scale`. Every other size in the sheet is either
    /// this or a fixed multiple of the base, so one ratio moves the document.
    /// Whole points, at every scale. ⌘+ multiplies by a ratio (14/13, 15/13 …),
    /// which lands type on fractions of a point — and a fractional size puts
    /// baselines between pixels, which is what makes text look soft rather than
    /// small.
    var bodySize: CGFloat { Self.snapped(Self.baseBodySize * scale) }

    /// Semibold at every level, not bold at the top two. GitHub, Apple's own
    /// documentation and most reading UIs settle on 600 — at 28pt, 700 is a
    /// shout, and size is already carrying the hierarchy.
    private func headingFont(_ level: Int) -> Font {
        .system(size: headingSize(level), weight: .semibold)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        Self.headingRatio(level) * bodySize
    }

    /// GitHub's heading scale, as multiples of the body size: 2, 1.5, 1.25, 1,
    /// then below it. Ems rather than points because these were points tuned for
    /// a 14pt body — raising the body to 16 left h2 and h3 behind, which is the
    /// kind of drift that only shows up as "the hierarchy feels flat".
    static func headingRatio(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 2
        case 2: return 1.5
        case 3: return 1.25
        case 4: return 1
        case 5: return 0.875
        default: return 0.85
        }
    }

    // MARK: - Inline markdown

    /// Inline markdown, with code spans drawn as chips.
    ///
    /// A code span in prose should read as a *chip* — monospaced and set off by a
    /// background — not merely as a change of typeface, which mid-sentence is
    /// barely visible. The parsing itself lives in `MarkdownInline`, which is
    /// pure Foundation and unit-tested.
    /// Inline markdown, with code spans drawn as chips.
    ///
    /// The chip is *drawn*, not set as a text background. `backgroundColor` on a
    /// run gives a flat rectangle sized to the run's own font — square corners,
    /// no padding, and sitting slightly off the prose because the monospaced face
    /// is smaller than the text around it. A `TextRenderer` gets the run's
    /// typographic bounds and can put a rounded, padded shape behind it, centred
    /// on the line the code actually sits on. Needs macOS 15; below that the flat
    /// background is the fallback, which is what this always was.
    @ViewBuilder
    private func styled(_ markdown: String, size: CGFloat) -> some View {
        if #available(macOS 15.0, *) {
            tagged(markdown, size: size)
                // Horizontal padding is layout (see `padding(for:)`), so the
                // renderer only adds the vertical, plus GitHub's 6px radius.
                .textRenderer(InlineCodeRenderer(
                    vertical: (size * 0.16).rounded(),
                    radius: (size * 0.375).rounded()))
        } else {
            Text(inline(markdown, size: size))
        }
    }

    /// Each run as its own `Text`, so the code ones can carry the marker the
    /// renderer looks for — a custom attribute applies to a `Text`, not to a
    /// range inside one, so the paragraph is concatenated rather than built as a
    /// single attributed string.
    @available(macOS 15.0, *)
    private func tagged(_ markdown: String, size: CGFloat) -> Text {
        let parsed = MarkdownInline.parse(markdown)
        let code = Self.codeSize(for: size)
        var result = Text("")
        for run in parsed.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            guard isCode else {
                result = result + Text(AttributedString(parsed[run.range]))
                continue
            }
            var piece = Self.padding(for: code)
            var body = AttributedString(parsed[run.range])
            body.font = .system(size: code, design: .monospaced)
            piece.append(body)
            piece.append(Self.padding(for: code))
            result = result + Text(piece).customAttribute(InlineCodeMarker())
        }
        return result
    }

    /// A space wide enough to be the chip's horizontal padding — as **layout**,
    /// not just as a drawn shape.
    ///
    /// This is the whole difference between a chip that sits in a sentence and
    /// one that collides with it. A `TextRenderer` can paint a box wider than the
    /// run, but the text around it knows nothing about that box, so the padding
    /// lands *on top of* the neighbouring word or comma. CSS padding widens the
    /// element itself; here the equivalent is a real space inside the run.
    ///
    /// Its size is the lever: measured, every space in a monospaced face has the
    /// same one-cell advance (~0.6em) whatever character you pick, so a thin
    /// space buys nothing — but that cell scales with the font, so a space set at
    /// ⅔ the code size lands at GitHub's .4em. It sits inside the tagged run, so
    /// the chip covers it, and being shorter than the code it never makes the
    /// chip taller.
    private static func padding(for codeSize: CGFloat) -> AttributedString {
        var space = AttributedString(" ")
        space.font = .system(size: (codeSize * 0.667).rounded(), design: .monospaced)
        return space
    }

    /// The pre-macOS-15 path: a flat background, square and unpadded.
    private func inline(_ markdown: String, size: CGFloat) -> AttributedString {
        var result = MarkdownInline.parse(markdown)
        // Collected first: mutating the string invalidates the runs being walked.
        let code = result.runs.compactMap {
            $0.inlinePresentationIntent?.contains(.code) == true ? $0.range : nil
        }
        for range in code {
            // 0.85, the ratio GitHub uses and roughly what it takes for a
            // monospaced face to *look* the same size as the prose around it:
            // its wide, even advance makes it read larger at equal points.
            result[range].font = .system(size: Self.codeSize(for: size), design: .monospaced)
            result[range].backgroundColor = Color.secondary.opacity(0.15)
        }
        return result
    }
}

// MARK: - Code block

/// A fenced code block: monospaced, tree-sitter–coloured with the GitHub palette
/// (the same `DiffSyntaxTheme` the diff view uses), in a rounded card that
/// scrolls horizontally for long lines. Highlighting runs off-main; until it
/// lands (or when the language is unknown) the plain monospaced text shows.
private struct CodeBlockView: View {
    let code: String
    let language: String?
    /// Same ratio the surrounding document uses, so code keeps its relationship
    /// to the prose around it at every size.
    var scale: CGFloat = 1

    /// Below the body size, like the inline chips — a monospaced face reads
    /// larger than a proportional one at equal points, and a code block set at
    /// full body size dominates the page it's meant to illustrate.
    private var codeSize: CGFloat {
        MarkdownView.codeSize(for: MarkdownView.baseBodySize * scale)
    }

    @State private var highlighted: AttributedString?

    /// GitHub's 1rem card padding, carried by the *contents* rather than by the
    /// card — see `body`.
    private var inset: CGFloat { (MarkdownView.baseBodySize * scale).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: (inset * 0.4).rounded()) {
            if let language, !language.isEmpty {
                Text(verbatim: language.uppercased())
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, inset)
                    .padding(.top, inset)
            }
            // Indicators on: a listing wider than the card is clipped at its
            // right edge, and without a scroller there is nothing to say the
            // rest exists — it reads as truncated rather than as scrollable.
            ScrollView(.horizontal) {
                // **The size is set here and nowhere else.** It used to be baked
                // into the attributed string, in two different places — the plain
                // path and the highlighted one — so a block with a language could
                // end up set differently from a block without one, and nothing
                // about either call site made that visible. A run's own `.font`
                // beats the view's, so leaving it off the string entirely is what
                // makes one size structurally impossible to disagree with.
                Text(highlighted ?? Self.plain(code))
                    .font(.system(size: codeSize, design: .monospaced))
                    // The padding lives on the text, so the scroll view itself
                    // runs to the card's edges and its overlay scroller sits on
                    // the bottom edge — where a scrollbar belongs — rather than
                    // floating in the middle of the padding, or across the last
                    // line of code as it did before that.
                    .padding(.horizontal, inset)
                    .padding(.top, language.map { $0.isEmpty ? inset : 0 } ?? inset)
                    .padding(.bottom, inset)
                    // Tighter than prose: code is scanned down columns rather
                    // than read across lines.
                    .lineSpacing(MarkdownView.lineSpacing(
                        for: .monospacedSystemFont(ofSize: codeSize, weight: .regular),
                        size: codeSize, ratio: 1.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor)))
        .task(id: code) { await highlight() }
    }

    /// No font: the view sets it, so every path renders at one size.
    private static func plain(_ code: String) -> AttributedString {
        AttributedString(code.isEmpty ? " " : code)
    }

    private func highlight() async {
        highlighted = nil
        guard let language, let grammar = Grammar(fence: language) else { return }
        let spans = await MarkdownCodeHighlighter.shared.spans(for: code, grammar: grammar)
        guard !spans.isEmpty else { return }
        highlighted = Self.colored(code: code, spans: spans)
    }

    /// Apply the tree-sitter spans in a single forward pass. Mapping each span's
    /// UTF-16 range to an AttributedString index on its own is O(n) per span (a
    /// walk from the start), which is quadratic over a large block; instead walk
    /// the string once, recording the index at every span boundary, then colour
    /// by lookup. Boundaries that fall mid-grapheme simply aren't recorded, so
    /// that span is skipped rather than mis-placed.
    private static func colored(
        code: String, spans: [(range: NSRange, token: HighlightToken)]
    ) -> AttributedString {
        var attr = plain(code)

        var boundaries: Set<Int> = []
        for (range, _) in spans {
            boundaries.insert(range.location)
            boundaries.insert(range.location + range.length)
        }

        var indexAt: [Int: AttributedString.Index] = [:]
        var index = attr.startIndex
        var utf16 = 0
        if boundaries.contains(0) { indexAt[0] = index }
        for character in code {
            utf16 += character.utf16.count
            index = attr.characters.index(after: index)
            if boundaries.contains(utf16) { indexAt[utf16] = index }
        }

        let theme = DiffSyntaxTheme()
        for (range, token) in spans {
            guard let lo = indexAt[range.location],
                  let hi = indexAt[range.location + range.length], lo < hi else { continue }
            attr[lo..<hi].foregroundColor = Color(nsColor: theme.color(for: token))
        }
        return attr
    }
}

// MARK: - Inline code chips

/// Marks the runs `InlineCodeRenderer` draws a chip behind.
@available(macOS 15.0, *)
struct InlineCodeMarker: TextAttribute {}

/// Draws a rounded, padded background behind inline code, then the text on top.
///
/// This exists because a text *attribute* can't do it: `backgroundColor` paints
/// a square, unpadded rectangle sized to the run's own font, which for a code
/// span set smaller than the prose around it sits visibly off the line. A
/// renderer gets each run's typographic bounds — ascent and descent included —
/// so the shape can be centred on the glyphs and padded on all four sides.
@available(macOS 15.0, *)
struct InlineCodeRenderer: TextRenderer {
    var vertical: CGFloat
    var radius: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let fill = GraphicsContext.Shading.color(.secondary.opacity(0.16))
        for line in layout {
            // Consecutive tagged runs are **one** chip. A code span is at least
            // three runs — its padding space, the code, its padding space — and
            // one rounded rect each would draw three pills in a row with seams
            // where they meet. A span that also carries emphasis splits further
            // still, so grouping is the general answer rather than a special case.
            var box: CGRect?
            func flush() {
                guard let current = box else { return }
                context.fill(
                    Path(roundedRect: current.insetBy(dx: 0, dy: -vertical),
                         cornerRadius: radius),
                    with: fill)
                box = nil
            }
            for run in line {
                guard run[InlineCodeMarker.self] != nil else {
                    flush()
                    continue
                }
                let rect = run.typographicBounds.rect
                box = box.map { $0.union(rect) } ?? rect
            }
            flush()
            context.draw(line)
        }
    }
}

private extension View {
    /// A table's frame: rounded corners and a hairline, clipped so the rows end
    /// where the border does. Applied to whichever view is the *viewport* — the
    /// grid itself when it fits, the scroll view when it doesn't.
    func framedAsTable() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor)))
    }
}

/// The `NSScrollView` behind a SwiftUI `ScrollView`, found from a view placed
/// inside its content: SwiftUI on macOS 14 can scroll to a view but not by a
/// distance, and `MarkdownView` needs both to put a reader back to the point.
/// A box rather than a binding, so finding it doesn't redraw anything.
@MainActor
final class EnclosingScrollView {
    weak var view: NSView?

    struct Marker: NSViewRepresentable {
        let box: EnclosingScrollView

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            box.view = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            box.view = view
        }
    }
}
