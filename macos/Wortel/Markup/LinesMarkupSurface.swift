import AppKit

/// Pictures of views the app draws itself, for mark-up over a file.
@MainActor
enum ViewPicture {
    /// The page's own colour, as this view shows it. A file's views draw no
    /// background of their own (the page behind them does), so a picture of
    /// one alone would be dark text on nothing.
    static func background(of view: NSView) -> CGColor {
        var colour = CGColor(gray: 1, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = Chrome.content.usingColorSpace(.sRGB)?.cgColor ?? Chrome.content.cgColor
        }
        return colour
    }

    /// What `view` shows in `rect` (its own coordinates), on the page's
    /// colour. The mark-up layer is never in it: it is no part of `view`.
    static func capture(_ view: NSView, rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let shot = rep.cgImage else { return nil }
        return onBackground(shot, background(of: view))
    }

    static func onBackground(_ image: CGImage, _ background: CGColor) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(all)
        context.draw(image, in: all)
        return context.makeImage()
    }

    /// Draw a stretch of what a scroll view scrolls into a canvas, a
    /// screen at a time: scroll, let the views lay out, take a picture,
    /// and put the scroll back where it was.
    ///
    /// All in one turn of the run loop, so nothing on screen moves: the
    /// window is only drawn again after the scroll is back. `top` and
    /// `bottom` are in the document view's coordinates; `place` says where
    /// a stretch of the document belongs in the canvas's whole.
    static func tiles(of scroll: NSScrollView, from top: CGFloat, to bottom: CGFloat,
                      into canvas: MarkupCanvas, place: (CGRect) -> CGRect) {
        let clip = scroll.contentView
        let start = clip.bounds.origin
        defer {
            clip.scroll(to: start)
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
        }
        var y = top
        for _ in 0..<64 where y < bottom {
            let wanted = NSRect(x: start.x, y: y, width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            let shown = scroll.documentVisibleRect
            if let image = capture(clip, rect: clip.bounds) {
                canvas.draw(image, at: place(shown))
            }
            // At the document's end the scroll stops short of what was asked.
            guard shown.maxY > y + 1 else { break }
            y = shown.maxY
        }
    }
}

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
    private var observers: [NSObjectProtocol] = []
    private weak var observed: NSView?

    private struct Tie {
        var row: Int
        let key: Int?
        /// The row height the mark was drawn at: its unit.
        let rowHeight: CGFloat
        var lost = false
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

    func attach(to layer: NSView) { self.layer = layer }

    func activate(moved: @escaping () -> Void) {
        self.moved = moved
        views.onChange = { [weak self] in self?.changed() }
        observe()
    }

    func deactivate(forgetting: Bool) {
        moved = nil
        views.onChange = {}
        stopObserving()
        if forgetting { ties = [:] }
    }

    /// Watch the clip view that is there now: the table is rebuilt with its
    /// tab, and the new one has a clip view of its own.
    private func observe() {
        guard let clip = scroll?.contentView, clip !== observed else { return }
        stopObserving()
        observed = clip
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.moved?() }
            })
        }
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        observed = nil
    }

    /// The rows changed: a file rewritten, the text resized, the table
    /// made anew. Each mark finds its row again, or has none.
    private func changed() {
        observe()
        let count = table?.numberOfRows ?? 0
        for (number, tie) in ties {
            guard let key = tie.key else { continue }
            if tie.row < count, views.rowKey(tie.row) == key {
                ties[number]?.lost = false
                continue
            }
            var found: Int?
            for distance in 1...Self.reach {
                if tie.row - distance >= 0, tie.row - distance < count, views.rowKey(tie.row - distance) == key {
                    found = tie.row - distance
                    break
                }
                if tie.row + distance < count, views.rowKey(tie.row + distance) == key {
                    found = tie.row + distance
                    break
                }
            }
            if let found { ties[number]?.row = found }
            ties[number]?.lost = found == nil
        }
        moved?()
    }

    // MARK: - Marks

    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
    func pick(_ number: Int, at point: CGPoint, reply: @escaping (MarkTie?) -> Void) { reply(nil) }

    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
        guard let table, let layer, table.numberOfRows > 0 else { return reply(nil) }
        let inTable = table.convert(box.origin, from: layer)
        var row = table.row(at: NSPoint(x: max(inTable.x, 0), y: inTable.y))
        // Above the first row or below the last: the nearest one.
        if row < 0 { row = inTable.y < 0 ? 0 : table.numberOfRows - 1 }
        ties[number] = Tie(row: row, key: views.rowKey(row), rowHeight: max(table.rowHeight, 1))
        guard let placement = placement(of: number) else { return reply(nil) }
        reply(MarkTie(placement: placement, name: nil, details: MarkDetails()))
    }

    func placement(of number: Int) -> MarkPlacement? {
        guard let tie = ties[number], !tie.lost, let table, let layer, let clip = scroll?.contentView,
              tie.row < table.numberOfRows else { return nil }
        let row = table.rect(ofRow: tie.row)
        return MarkPlacement(origin: layer.convert(row.origin, from: table), size: row.size,
                             scale: table.rowHeight / tie.rowHeight,
                             clip: layer.convert(clip.bounds, from: clip).intersection(layer.bounds))
    }

    func forget(_ number: Int) { ties[number] = nil }

    /// A table's marks move in the frame its rows do. Nothing is ever owed.
    func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool { false }

    // MARK: - Pictures

    func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) {
        guard let layer, let clip = scroll?.contentView else { return reply(nil) }
        let shown = layer.convert(clip.bounds, from: clip).intersection(rect).integral
        guard !shown.isNull, let image = ViewPicture.capture(clip, rect: clip.convert(shown, from: layer)) else {
            return reply(nil)
        }
        reply(MarkCapture(image: image, showing: shown))
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
