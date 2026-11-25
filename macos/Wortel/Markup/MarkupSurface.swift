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

    /// Start telling where the marks are. `moved` is called whenever a
    /// placement may have changed.
    func activate(moved: @escaping () -> Void)
    /// Stop, and let go of everything `activate` added. `forgetting` also
    /// drops what the marks were tied to: there is no note to come back to.
    func deactivate(forgetting: Bool)

    /// What a click at `point` would pick, to outline it. Nil for nothing.
    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void)
    /// Tie mark `number` to the thing at `point`.
    func pick(_ number: Int, at point: CGPoint, reply: @escaping (MarkTie?) -> Void)
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
    func capture(_ rect: CGRect, reply: @escaping (CGImage?) -> Void)
    /// A picture of the whole of what is previewed, without the marks, and
    /// where each mark is in it.
    func whole(reply: @escaping (MarkupWhole?) -> Void)
}

/// What a mark was tied to, and what there is to say about it.
struct MarkTie {
    /// Where it is now.
    var placement: MarkPlacement
    /// What it is called, when it has a name of its own.
    var name: String?
    var details: MarkDetails
}

/// The whole of what is previewed, to draw every mark on.
struct MarkupWhole {
    /// Draws the whole into a context `size` large, counted from the
    /// top-left. Called off the main thread.
    var draw: @Sendable (CGContext) -> Void
    /// Its size, in the units `placements` are in.
    var size: CGSize
    /// The part that was in view, in the same units.
    var visible: CGRect
    /// Where each mark is in the whole.
    var placements: [Int: MarkPlacement]
}
