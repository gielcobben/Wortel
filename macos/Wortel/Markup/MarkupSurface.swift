import AppKit

/// What the mark-up layer needs from the preview under it.
///
/// The layer is one view for every kind of preview. What differs per kind is
/// how a mark stays on its content (a page tells where an element is, a table
/// has rows), and how a picture of an area is taken. That is this protocol:
/// one adapter per kind of preview, and the layer never asks what it is over.
///
/// Every point and rect here is in `view`'s coordinates, which the layer
/// shares: it has the view's frame, and both count from the top-left.
///
/// **Everything an adapter registers (a script, a message handler, an
/// observer) is added in `activate` and removed in `deactivate`.** That is
/// what makes "mark-up off costs nothing" a thing to check, not to hope.
@MainActor
protocol MarkupSurface: AnyObject {
    /// The view the marks lie over. Scrolling is passed on to it.
    var view: NSView? { get }
    /// Whether a click picks a thing here (an element of a page). Where it
    /// does not, only a drag makes a mark.
    var picksThings: Bool { get }

    /// Where the marks are drawn, told before `activate`. A requirement
    /// and not only a default below: declared in the extension alone, a
    /// call through `any MarkupSurface` runs the empty default whatever
    /// the adapter implements, and every file's mark was then tied to
    /// nothing (found by hand, 2026-11-25; the adapters' own tests call
    /// them by their type and saw none of it).
    func attach(to layer: NSView)
    /// Whether scrolling goes to whatever is under the pointer inside
    /// `view` (a code block that scrolls sideways within a document), not
    /// to `view` itself.
    var scrollsInside: Bool { get }

    /// The column the preview is read in, where it has one narrower than
    /// itself (rendered Markdown): the note bar lines up with it. Nil for
    /// a preview that is read edge to edge.
    var readingColumn: CGRect? { get }
    /// Bring a mark's own box into the part of `view` that shows, if it is
    /// not wholly there: its chip was clicked. The bottom `covered` points
    /// are under the note bar and do not count as shown. Where it goes is
    /// `MarkReveal.shift`.
    func reveal(_ mark: Mark, coveredBelow covered: CGFloat)

    /// Start telling where the marks are. `moved` is called whenever a
    /// placement may have changed.
    func activate(moved: @escaping () -> Void)
    /// Stop, and let go of everything `activate` added. `forgetting` also
    /// drops what the marks were tied to: there is no note to come back to.
    func deactivate(forgetting: Bool)

    /// What a click at `point` would pick, to outline it. Nil for nothing.
    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void)
    /// Tie mark `number` to the thing at `point`, unless that thing is
    /// already one of `picked`: the marks made by picking whose chips are
    /// in the note. Then the answer is that mark, and `number` is not used.
    func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void)
    /// Tie mark `number` to what lies under `box`.
    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void)
    /// Where a mark is now, or nil when what it was tied to is gone or has
    /// not been reported yet.
    func placement(of number: Int) -> MarkPlacement?
    func forget(_ number: Int)
    /// Whether scrolling by this much should move the marks. Where it
    /// should and no word of it comes, the marks are behind their content.
    func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool

    /// A picture of what `rect` shows, without the marks.
    func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void)
    /// A picture of the whole of what is previewed, without the marks, and
    /// where each of `marks` is in it.
    func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void)
}

/// A picture of part of the view, and the part it shows: what was asked
/// for, cut to what there is (a page has nothing past its view's edge, an
/// image nothing outside the picture).
struct MarkCapture {
    var image: CGImage
    var showing: CGRect
}

extension MarkupSurface {
    /// Where the marks are drawn. A page's layer has its web view's own
    /// frame, so the two share coordinates and there is nothing to do. A
    /// file's layer is placed by SwiftUI over views SwiftUI also places, so
    /// its adapters convert through this view.
    func attach(to layer: NSView) {}
    var scrollsInside: Bool { false }
    var readingColumn: CGRect? { nil }
}

/// The views a file's preview is drawn with, as they come and go.
///
/// A file tab's views are rebuilt whenever the tab comes back from behind
/// others; its marks must not be. So the adapter that ties marks to a
/// file's content lives with the session, and the views register here as
/// they are made: the table of Source and Diff, the stack of rendered
/// Markdown, the picture of an image. Weak, all of it: nothing here keeps
/// a view alive.
@MainActor
final class MarkupViews {
    // Source and Diff (`DiffView`).
    weak var table: NSTableView?
    /// What a row holds, as a number that changes when its line does, so a
    /// mark can tell its line from another that took its place.
    var rowKey: (Int) -> Int? = { _ in nil }

    // Rendered Markdown (`MarkdownView`).
    /// A view exactly as large as the stack of blocks, inside the scroll
    /// view: block frames are measured from its top-left.
    weak var stack: NSView?
    /// Where each block that is built sits in the stack. The stack is
    /// lazy: a block far out of view is not here.
    var blockFrames: [Int: CGRect] = [:]
    var blockKey: (Int) -> Int? = { _ in nil }
    /// The document's type scale: ⌘+ moves it, and a mark with it.
    var blockScale: CGFloat = 1
    /// Scroll a block into the middle of the view. Only the document's own
    /// scroll reader can: a block that is not built has no frame to scroll
    /// to. It lands near, not exactly: the mark is placed once the block
    /// has its frame (`BlocksMarkupSurface.reveal`).
    var revealBlock: (Int) -> Void = { _ in }

    // An image, or an SVG's picture (`ImagePreview`).
    weak var image: NSImageView?

    /// What is shown changed under the marks: a file rewritten, a block
    /// built or measured, the text resized.
    var onChange: () -> Void = {}

    func changed() { onChange() }
}

/// What a mark was tied to, and what there is to say about it.
struct MarkTie {
    /// Where it is now.
    var placement: MarkPlacement
    /// What it is called, when it has a name of its own.
    var name: String?
    var details: MarkDetails
}

/// What a click on a thing came to.
enum MarkPick {
    /// A new mark, tied to it.
    case tied(MarkTie)
    /// The thing is already this mark, picked before: a second mark on it
    /// would be two numbers for one thing, so its chip is selected instead.
    case already(Int)
}

/// The whole of what is previewed, to draw every mark on.
struct MarkupWhole {
    /// How the whole gets into the picture.
    enum Source {
        /// Draws all of it into a context counted from its bottom-left, as
        /// CoreGraphics counts. Called off the main thread. A page, whose
        /// PDF draws any part of itself.
        case draw(@Sendable (CGContext) -> Void)
        /// The part to picture, already drawn. A table has to be scrolled
        /// to be drawn, which only the main thread can do, so it comes
        /// with its picture made.
        case canvas(MarkupCanvas)
    }

    var source: Source
    /// Its size, in the units `placements` are in.
    var size: CGSize
    /// The part that was in view, in the same units.
    var visible: CGRect
    /// Where each mark is in the whole.
    var placements: [Int: MarkPlacement]
    /// What is behind it where it draws nothing.
    var background = CGColor(gray: 1, alpha: 1)

    init(draw: @escaping @Sendable (CGContext) -> Void, size: CGSize, visible: CGRect,
         placements: [Int: MarkPlacement]) {
        source = .draw(draw)
        self.size = size
        self.visible = visible
        self.placements = placements
    }

    init(canvas: MarkupCanvas, size: CGSize, visible: CGRect, placements: [Int: MarkPlacement]) {
        source = .canvas(canvas)
        self.size = size
        self.visible = visible
        self.placements = placements
    }
}

/// A picture being made of part of a whole: a bitmap, set up so that what
/// is drawn into it is drawn in the whole's own units, counted from the
/// whole's bottom-left.
final class MarkupCanvas: @unchecked Sendable {
    let context: CGContext
    /// The part of the whole it holds, counted from the whole's top-left.
    let part: CGRect
    /// Whether that is less than all of it.
    let isPart: Bool
    /// Whether it is only what was in view, and not chosen for the marks.
    var isView = false
    /// Pixels per unit.
    let density: CGFloat
    let wholeHeight: CGFloat

    init?(part: CGRect, isPart: Bool, wholeHeight: CGFloat, background: CGColor) {
        let density = MarkupPicture.density(for: part.size)
        let width = Int((part.width * density).rounded(.up)), height = Int((part.height * density).rounded(.up))
        guard width >= 1, height >= 1,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: density, y: density)
        // The part's bottom-left corner to the picture's: the whole counts
        // from its own bottom, which is `wholeHeight - part.maxY` below.
        context.translateBy(x: -part.minX, y: -(wholeHeight - part.maxY))
        self.context = context
        self.part = part
        self.isPart = isPart
        self.density = density
        self.wholeHeight = wholeHeight
    }

    /// Draw a picture of `rect` of the whole (counted from its top-left).
    func draw(_ image: CGImage, at rect: CGRect) {
        context.draw(image, in: CGRect(x: rect.minX, y: wholeHeight - rect.maxY, width: rect.width, height: rect.height))
    }
}
