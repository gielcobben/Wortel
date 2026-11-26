import AppKit

/// Mark-up over rendered Markdown: `MarkdownView`'s stack of blocks.
///
/// A mark is tied to a block (a paragraph, a heading, a code block), and
/// kept as an offset from that block's corner. Not to a place in the
/// document: the stack is lazy, the blocks above the view have heights
/// that are only guesses until they are built, and every guess corrected
/// moves everything below it. `MainArea` records the same drift for a
/// reader's place. A block's own frame is always right when it has one.
///
/// A block that is not built has no frame, and a mark on it is not drawn.
/// It is out of view then anyway, and is drawn again when it comes back.
///
/// The frames come from `MarkdownView` through `MarkupViews`, measured in
/// the stack, and only while mark-up is on. They do not change when the
/// document scrolls, so scrolling costs no SwiftUI update: the clip view
/// says its bounds changed, and the frames are converted again.
@MainActor
final class BlocksMarkupSurface: MarkupSurface {
    private let views: MarkupViews
    private weak var layer: NSView?
    private var moved: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private weak var observed: NSView?

    private struct Tie {
        /// The block, and what it and the blocks around it held.
        var anchor: MarkAnchor
        /// The document's type scale the mark was drawn at: its unit.
        let scale: CGFloat
        var lost = false

        var block: Int { anchor.index }
    }
    private var ties: [Int: Tie] = [:]

    /// How many blocks either side a block is looked for after the file
    /// changed.
    private static let reach = 60

    init(views: MarkupViews) {
        self.views = views
    }

    private var stack: NSView? { views.stack }
    private var scroll: NSScrollView? { views.stack?.enclosingScrollView }

    var view: NSView? { scroll }
    var picksThings: Bool { false }
    /// A code block or a wide table scrolls sideways inside the document.
    var scrollsInside: Bool { true }

    func attach(to layer: NSView) { self.layer = layer }

    func activate(moved: @escaping () -> Void) {
        self.moved = moved
        views.onChange = { [weak self] in self?.changed() }
        observe()
        // The file may have been rewritten while nothing was listening,
        // and the document says where its blocks are before this layer is
        // in its window, so no word of the change comes after. Measured
        // 2026-11-25: three paragraphs added above two marks while mark-up
        // was off, and turned on again they were 226 and 395pt above their
        // paragraphs, for good.
        find()
    }

    func deactivate(forgetting: Bool) {
        moved = nil
        views.onChange = {}
        stopObserving()
        if forgetting { ties = [:] }
    }

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

    /// Blocks were built, measured or replaced. A mark whose block now
    /// holds something else looks for its own nearby.
    private func changed() {
        observe()
        find()
        moved?()
    }

    private func find() {
        for number in Array(ties.keys) {
            guard var tie = ties[number] else { continue }
            tie.lost = !tie.anchor.find(within: Self.reach, keyAt: views.blockKey)
            ties[number] = tie
        }
    }

    // MARK: - The stack's coordinates

    // SwiftUI measures a block from the stack's top-left. The view that
    // stands for the stack is a plain one, which counts from the bottom
    // unless it says otherwise.

    private func toLayer(_ point: CGPoint) -> CGPoint? {
        guard let stack, let layer else { return nil }
        return layer.convert(NSPoint(x: point.x, y: stack.isFlipped ? point.y : stack.bounds.height - point.y),
                             from: stack)
    }

    private func fromLayer(_ point: CGPoint) -> CGPoint? {
        guard let stack, let layer else { return nil }
        let inStack = stack.convert(point, from: layer)
        return CGPoint(x: inStack.x, y: stack.isFlipped ? inStack.y : stack.bounds.height - inStack.y)
    }

    /// A rect of some view, as a rect of the stack counted from its top-left.
    private func inStack(_ rect: CGRect, of view: NSView) -> CGRect? {
        guard let stack else { return nil }
        let converted = stack.convert(rect, from: view)
        return CGRect(x: converted.minX,
                      y: stack.isFlipped ? converted.minY : stack.bounds.height - converted.maxY,
                      width: converted.width, height: converted.height)
    }

    // MARK: - Marks

    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
    func pick(_ number: Int, at point: CGPoint, reply: @escaping (MarkTie?) -> Void) { reply(nil) }

    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
        guard let corner = fromLayer(box.origin), !views.blockFrames.isEmpty else { return reply(nil) }
        // The block the area starts in, or the nearest to where it starts.
        func distance(_ frame: CGRect) -> CGFloat {
            corner.y < frame.minY ? frame.minY - corner.y : corner.y > frame.maxY ? corner.y - frame.maxY : 0
        }
        guard let block = views.blockFrames.min(by: { distance($0.value) < distance($1.value) })?.key else {
            return reply(nil)
        }
        ties[number] = Tie(anchor: MarkAnchor(at: block, keyAt: views.blockKey), scale: max(views.blockScale, 0.01))
        guard let placement = placement(of: number) else { return reply(nil) }
        reply(MarkTie(placement: placement, name: nil, details: MarkDetails()))
    }

    func placement(of number: Int) -> MarkPlacement? {
        guard let tie = ties[number], !tie.lost, let frame = views.blockFrames[tie.block],
              let origin = toLayer(frame.origin), let layer, let clip = scroll?.contentView else { return nil }
        return MarkPlacement(origin: origin, size: frame.size, scale: views.blockScale / tie.scale,
                             clip: layer.convert(clip.bounds, from: clip).intersection(layer.bounds))
    }

    func forget(_ number: Int) { ties[number] = nil }

    /// The document scrolls its block to the middle. Asked of the view and
    /// not done here: a block out of view has no frame to scroll to.
    func reveal(_ number: Int) {
        guard let tie = ties[number], !tie.lost else { return }
        if let placement = placement(of: number),
           placement.clip.contains(CGRect(origin: placement.origin, size: placement.size)) { return }
        views.revealBlock(tie.block)
    }

    /// The column the document is read in: every block is as wide as the
    /// measure, so any built block gives it.
    var readingColumn: CGRect? {
        guard let frame = views.blockFrames.values.min(by: { $0.width < $1.width }),
              let origin = toLayer(frame.origin) else { return nil }
        return CGRect(x: origin.x, y: 0, width: frame.width, height: 0)
    }
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

    /// The document as it is in view, with the marks that are in view.
    ///
    /// Not the whole document, which a page and a file's source give. The
    /// blocks out of view are not built, building them takes the stack a
    /// turn of the run loop a screen, and the document would have to be
    /// seen scrolling from end to end to be pictured. Each mark has its
    /// own picture, taken when it was made. The copied text says this is a
    /// part.
    func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) {
        guard let stack, let scroll, let visible = inStack(scroll.contentView.bounds, of: scroll.contentView),
              let image = ViewPicture.capture(scroll.contentView, rect: scroll.contentView.bounds) else {
            return reply(nil)
        }
        let size = stack.bounds.size
        let all = CGRect(origin: .zero, size: size)
        var placements: [Int: MarkPlacement] = [:]
        for (number, tie) in ties where !tie.lost {
            guard let frame = views.blockFrames[tie.block] else { continue }
            placements[number] = MarkPlacement(origin: frame.origin, size: frame.size,
                                               scale: views.blockScale / tie.scale, clip: all)
        }
        // The view shows more than the stack: its margins. The picture is
        // the view, placed in the stack's coordinates, margins and all.
        guard let canvas = MarkupCanvas(part: visible, isPart: true, wholeHeight: size.height,
                                        background: ViewPicture.background(of: stack)) else { return reply(nil) }
        canvas.isView = true
        canvas.draw(image, at: visible)
        reply(MarkupWhole(canvas: canvas, size: size, visible: visible, placements: placements))
    }
}
