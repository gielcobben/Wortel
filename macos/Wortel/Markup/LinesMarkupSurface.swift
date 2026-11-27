import AppKit

/// Mark-up over a file's source or its diff: `DiffView`'s table.
///
/// A mark is tied to a row. The table and its scroll view are the app's
/// own, in its own process, so the marks move in the same frame as the
/// rows: the clip view says its bounds changed and the layer places them
/// before the window is drawn. The row's height is the unit, so ⌘+ scales
/// a mark with the text.
///
/// A file is rewritten under its preview all day (that is what an agent
/// does). A mark remembers what its row held, as a key: after a change it
/// looks for that row again near where it was, and when the line is gone
/// the mark has no place, while its chip and its picture stay.
///
/// Areas only: a click picks nothing here. Picking a line, and the lines'
/// own text in what is copied, is the next phase.
@MainActor
final class LinesMarkupSurface: MarkupSurface {
    private let views: MarkupViews
    private weak var layer: NSView?
    private var moved: (() -> Void)?
    private let watch = ViewWatch()

    private struct Tie {
        /// The row, and what it and the rows around it held.
        var anchor: MarkAnchor
        /// The row height the mark was drawn at: its unit.
        let rowHeight: CGFloat
        var lost = false

        var row: Int { anchor.index }
    }
    private var ties: [Int: Tie] = [:]

    /// How far from where it was a row is looked for after the file changed.
    private static let reach = 400

    init(views: MarkupViews) {
        self.views = views
    }

    private var table: NSTableView? { views.table }
    private var scroll: NSScrollView? { views.table?.enclosingScrollView }

    var view: NSView? { scroll }
    var picksThings: Bool { false }
    var scrollsInside: Bool { false }
    var readingColumn: CGRect? { nil }

    // MARK: - On and off

    func attach(to layer: NSView) { self.layer = layer }

    func activate(moved: @escaping () -> Void) {
        self.moved = moved
        views.onChange = { [weak self] in self?.changed() }
        observe()
        // The file may have been rewritten while nothing was listening:
        // after a copy mark-up is off, and the agent that was handed the
        // note edits this very file. Measured 2026-11-25: three lines added
        // above a mark while mark-up was off, and turned on again the mark
        // was three rows above its line, for good.
        find()
    }

    func deactivate(forgetting: Bool) {
        moved = nil
        views.onChange = {}
        watch.stop()
        if forgetting { ties = [:] }
    }

    /// Watch the clip view that is there now: the table is rebuilt with its
    /// tab, and the new one has a clip view of its own.
    private func observe() {
        watch.watch(scroll?.contentView, scrolling: true) { [weak self] in self?.moved?() }
    }

    /// The rows changed: a file rewritten, the text resized, the table
    /// made anew. Each mark finds its row again, or has none.
    private func changed() {
        observe()
        find()
        moved?()
    }

    private func find() {
        for number in Array(ties.keys) {
            guard var tie = ties[number] else { continue }
            tie.lost = !tie.anchor.find(within: Self.reach, keyAt: views.rowKey)
            ties[number] = tie
        }
    }

    // MARK: - Marks

    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
    func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) { reply(nil) }

    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
        guard let table, let layer, table.numberOfRows > 0 else { return reply(nil) }
        // The row the ink starts on: `box` is the area, with room around it.
        let inTable = table.convert(MarkStroke.inkCorner(of: box), from: layer)
        var row = table.row(at: NSPoint(x: max(inTable.x, 0), y: inTable.y))
        // Above the first row or below the last: the nearest one.
        if row < 0 { row = inTable.y < 0 ? 0 : table.numberOfRows - 1 }
        ties[number] = Tie(anchor: MarkAnchor(at: row, keyAt: views.rowKey), rowHeight: max(table.rowHeight, 1))
        guard let placement = placement(of: number) else { return reply(nil) }
        reply(MarkTie(placement: placement, name: nil, details: MarkDetails()))
    }

    func placement(of number: Int) -> MarkPlacement? {
        guard let tie = ties[number], !tie.lost, let table, let layer, let scroll,
              tie.row < table.numberOfRows else { return nil }
        let row = table.rect(ofRow: tie.row)
        return MarkPlacement(origin: layer.convert(row.origin, from: table), size: row.size,
                             scale: table.rowHeight / tie.rowHeight,
                             clip: scroll.clip(in: layer).intersection(layer.bounds))
    }

    func forget(_ number: Int) { ties[number] = nil }

    // MARK: - Scrolling

    /// The mark's box, not its first row: a box over eight lines whose
    /// first was in view was left half under the note bar, which the row
    /// alone could not tell.
    func reveal(_ mark: Mark, coveredBelow covered: CGFloat) {
        guard let layer, let scroll, let placement = placement(of: mark.number) else { return }
        scroll.reveal(placement.box(of: mark.shape), within: placement.clip, of: layer, coveredBelow: covered)
    }

    /// A table's marks move in the frame its rows do. Nothing is ever owed.
    func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool { false }

    // MARK: - Pictures

    func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) {
        guard let layer, let scroll else { return reply(nil) }
        reply(ViewPicture.capture(rect, of: scroll, under: layer))
    }

    func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) {
        guard let table, let scroll else { return reply(nil) }
        let size = table.bounds.size
        let visible = scroll.documentVisibleRect
        let all = CGRect(origin: .zero, size: size)
        var placements: [Int: MarkPlacement] = [:]
        for (number, tie) in ties where !tie.lost && tie.row < table.numberOfRows {
            let row = table.rect(ofRow: tie.row)
            placements[number] = MarkPlacement(origin: row.origin, size: row.size,
                                               scale: table.rowHeight / tie.rowHeight, clip: all)
        }
        var (part, isPart) = MarkupPicture.part(
            of: size, screen: visible.height,
            marks: marks.compactMap { mark in placements[mark.number]?.box(of: mark.shape) })
        // As wide as the view, where it is scrolled to sideways: one very
        // long line would otherwise make every other line too small to read.
        part.origin.x = visible.minX
        part.size.width = max(min(visible.width, size.width - visible.minX), 1)
        guard let canvas = MarkupCanvas(part: part, isPart: isPart, wholeHeight: size.height,
                                        background: ViewPicture.background(of: table)) else { return reply(nil) }
        ViewPicture.tiles(of: scroll, from: part.minY, to: part.maxY, into: canvas) { $0 }
        reply(MarkupWhole(canvas: canvas, size: size, visible: visible, placements: placements))
    }
}
