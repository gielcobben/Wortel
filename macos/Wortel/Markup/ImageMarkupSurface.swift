import AppKit

/// Mark-up over an image, or the picture an SVG makes.
///
/// Every mark is tied to the picture itself, in the picture's own points:
/// it does not scroll, and the only thing that moves it is the view being
/// resized, which scales the picture down to fit. So a mark's unit is how
/// large one point of the picture is shown.
///
/// A mark's picture is not a snapshot of the screen. It is cut from the
/// file's own pixels, which for a screenshot shown at half its size is four
/// times what the screen has.
@MainActor
final class ImageMarkupSurface: MarkupSurface {
    private let views: MarkupViews
    private weak var layer: NSView?
    private var moved: (() -> Void)?
    private var observer: NSObjectProtocol?
    private weak var observed: NSView?
    private var tied: Set<Int> = []

    init(views: MarkupViews) {
        self.views = views
    }

    var view: NSView? { views.image }
    var picksThings: Bool { false }

    func attach(to layer: NSView) { self.layer = layer }

    func activate(moved: @escaping () -> Void) {
        self.moved = moved
        views.onChange = { [weak self] in
            self?.observe()
            self?.moved?()
        }
        observe()
    }

    func deactivate(forgetting: Bool) {
        moved = nil
        views.onChange = {}
        stopObserving()
        if forgetting { tied = [] }
    }

    private func observe() {
        guard let image = views.image, image !== observed else { return }
        stopObserving()
        observed = image
        image.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: image, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.moved?() }
            }
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observed = nil
    }

    /// Where the picture is drawn in the layer, and how large one of its
    /// points is. The view scales it down to fit and never up, centred.
    private var shown: (rect: CGRect, scale: CGFloat)? {
        guard let view = views.image, let layer, let image = view.image,
              image.size.width > 0, image.size.height > 0 else { return nil }
        let frame = layer.convert(view.bounds, from: view)
        let scale = min(1, frame.width / image.size.width, frame.height / image.size.height)
        guard scale > 0 else { return nil }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return (CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                       width: size.width, height: size.height), scale)
    }

    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) { reply(nil) }
    func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) { reply(nil) }

    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
        // Drawn wholly beside the picture: there is nothing there to mark.
        guard let shown, shown.rect.intersects(box) else { return reply(nil) }
        tied.insert(number)
        guard let placement = placement(of: number) else { return reply(nil) }
        reply(MarkTie(placement: placement, name: nil, details: MarkDetails()))
    }

    func placement(of number: Int) -> MarkPlacement? {
        guard tied.contains(number), let shown, let layer else { return nil }
        return MarkPlacement(origin: shown.rect.origin, size: shown.rect.size, scale: shown.scale,
                             clip: layer.bounds)
    }

    func forget(_ number: Int) { tied.remove(number) }
    /// A picture is fitted to its view: all of it is always in view.
    func reveal(_ mark: Mark, coveredBelow covered: CGFloat) {}
    func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool { false }

    // MARK: - Pictures

    /// The file's own pixels: its largest bitmap, which the preview has
    /// decoded already. Or, for a picture with no pixels of its own (an
    /// SVG, a PDF page), twice its size in points and never more than
    /// `ViewPicture.mostPixels` a side: an SVG's size is whatever the file
    /// declares, and one that declares 100,000 points must not be drawn
    /// into a bitmap of 200,000.
    private static func pixels(of image: NSImage) -> CGImage? {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let largest = bitmaps.max(by: { $0.pixelsWide < $1.pixelsWide }), let pixels = largest.cgImage {
            return pixels
        }
        let most = CGFloat(ViewPicture.mostPixels)
        let scale = min(2, most / image.size.width, most / image.size.height)
        guard scale > 0, scale.isFinite else { return nil }
        var rect = CGRect(x: 0, y: 0, width: max((image.size.width * scale).rounded(), 1),
                          height: max((image.size.height * scale).rounded(), 1))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) {
        guard let shown, let view = views.image, let image = view.image,
              let pixels = Self.pixels(of: image) else { return reply(nil) }
        let inside = rect.intersection(shown.rect)
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return reply(nil) }
        let perPoint = CGSize(width: CGFloat(pixels.width) / image.size.width,
                              height: CGFloat(pixels.height) / image.size.height)
        let crop = CGRect(x: (inside.minX - shown.rect.minX) / shown.scale * perPoint.width,
                          y: (inside.minY - shown.rect.minY) / shown.scale * perPoint.height,
                          width: inside.width / shown.scale * perPoint.width,
                          height: inside.height / shown.scale * perPoint.height)
            .integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cut = pixels.cropping(to: crop),
              let picture = ViewPicture.onBackground(cut, ViewPicture.background(of: view)) else { return reply(nil) }
        reply(MarkCapture(image: picture, showing: inside))
    }

    func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) {
        guard let view = views.image, let image = view.image, let pixels = Self.pixels(of: image),
              image.size.width > 0, image.size.height > 0 else { return reply(nil) }
        let size = image.size
        let all = CGRect(origin: .zero, size: size)
        var placements: [Int: MarkPlacement] = [:]
        for number in tied {
            placements[number] = MarkPlacement(origin: .zero, size: size, scale: 1, clip: all)
        }
        let held = Pixels(image: pixels)
        var whole = MarkupWhole(draw: { context in
            context.draw(held.image, in: CGRect(origin: .zero, size: size))
        }, size: size, visible: all, placements: placements)
        whole.background = ViewPicture.background(of: view)
        reply(whole)
    }

    /// A picture's pixels, to draw on another thread.
    private struct Pixels: @unchecked Sendable {
        let image: CGImage
    }
}
