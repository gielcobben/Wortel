import AppKit

// Mark-up over a file: what its three adapters share. Where they find the
// views a file is drawn with, how they hear one of those views move, and
// what the two that lie over a scroll view ask of it.

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

/// Hears one of a file's views move: its frame, and for a clip view its
/// bounds too, which is its scroll.
///
/// The view is the app's own, in its own process, so the marks are placed
/// in the frame the content moves in, before the window is drawn.
@MainActor
final class ViewWatch {
    private var observers: [NSObjectProtocol] = []
    private weak var watched: NSView?

    /// Watch the view that is there now, unless it is the one watched
    /// already: a tab's views are made anew when it comes back from behind
    /// others, and the new ones are what moves from then on.
    func watch(_ view: NSView?, scrolling: Bool = false, moved: @escaping @MainActor @Sendable () -> Void) {
        guard let view, view !== watched else { return }
        stop()
        watched = view
        var names = [NSView.frameDidChangeNotification]
        view.postsFrameChangedNotifications = true
        if scrolling {
            names.append(NSView.boundsDidChangeNotification)
            view.postsBoundsChangedNotifications = true
        }
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { _ in
                MainActor.assumeIsolated { moved() }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        watched = nil
    }
}

extension NSScrollView {
    /// Where the clip view is in `layer`: the part of the scroll view that
    /// shows what is scrolled, with no scroller in it.
    func clip(in layer: NSView) -> CGRect {
        layer.convert(contentView.bounds, from: contentView)
    }

    /// Scroll so that `box` shows in the part of `clip` the note bar leaves
    /// (`MarkReveal`), both in `layer`'s points.
    func reveal(_ box: CGRect, within clip: CGRect, of layer: NSView, coveredBelow covered: CGFloat,
                moving: Bool = false) {
        let room = MarkReveal.room(layer.bounds.size, coveredBelow: covered).intersection(clip)
        slide(by: MarkReveal.shift(box, into: room, moving: moving), measuredIn: layer)
    }

    /// Move what is scrolled by `shift`, measured in `view`'s points, as
    /// far as the document lets it go. At once: the rows of a table and the
    /// blocks of a document are the app's own and are drawn in this frame.
    func slide(by shift: CGVector, measuredIn view: NSView) {
        guard shift.dx != 0 || shift.dy != 0 else { return }
        let clip = contentView
        // Through two points, so a flipped view and one that is not agree.
        let zero = clip.convert(NSPoint.zero, from: view)
        let moved = clip.convert(NSPoint(x: shift.dx, y: shift.dy), from: view)
        var bounds = clip.bounds
        bounds.origin.x -= moved.x - zero.x
        bounds.origin.y -= moved.y - zero.y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clip)
    }
}
