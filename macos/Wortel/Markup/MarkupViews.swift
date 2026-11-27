import AppKit

// Mark-up over a file: what its three adapters share. Where they find the
// views a file is drawn with, how they hear one of those views move, and
// what the two that lie over a scroll view ask of it.

/// The views a file's preview is drawn with, as they come and go.
///
/// A file tab's views are rebuilt whenever the tab comes back from behind
/// others; its marks must not be. So the adapter that ties marks to a
/// file's content lives with the session, and the views sign in here as
/// they are made: the table of Source and Diff, the stack of rendered
/// Markdown, the picture of an image. Weak, all of it: nothing here keeps
/// a view alive.
///
/// **One file can be on screen more than once**: its session is one per
/// path, app-wide, and two windows, or two splits of one, can each show
/// it. Each of those previews signs in its own views, and what is read
/// here is the one under the layer the marks are drawn on now (`layer`,
/// told by the adapter's `attach`). It was one slot each, which the last
/// preview to update took: a mark drawn in one window was tied through the
/// other window's table, to whatever line was at that height there (found
/// in review, 2026-11-27).
@MainActor
final class MarkupViews {
    /// The layer the marks are drawn on now. Weak: the layer is the view
    /// hierarchy's.
    weak var layer: NSView?

    private struct Table {
        weak var view: NSTableView?
        /// What a row holds, as a number that changes when its line does,
        /// so a mark can tell its line from another that took its place.
        var rowKey: (Int) -> Int?
    }

    private struct Stack {
        /// A view exactly as large as the stack of blocks, inside the
        /// scroll view: block frames are measured from its top-left.
        weak var view: NSView?
        /// Where each block that is built sits in the stack. The stack is
        /// lazy: a block far out of view is not here.
        var frames: [Int: CGRect]
        /// The document's type scale: ⌘+ moves it, and a mark with it.
        var scale: CGFloat
        var key: (Int) -> Int?
        /// Scroll a block into the middle of the view. Only the document's
        /// own scroll reader can: a block that is not built has no frame
        /// to scroll to. It lands near, not exactly: the mark is placed
        /// once the block has its frame (`BlocksMarkupSurface.reveal`).
        var reveal: (Int) -> Void
    }

    private struct Image {
        weak var view: NSImageView?
    }

    private var tables: [Table] = []
    private var stacks: [Stack] = []
    private var images: [Image] = []

    // MARK: - Signing in

    /// Source and Diff (`DiffView`): its table, each time it updates. Heard
    /// as a change only when the table is new.
    func sign(_ table: NSTableView, rowKey: @escaping (Int) -> Int?) {
        tables.removeAll { $0.view == nil }
        guard !tables.contains(where: { $0.view === table }) else { return }
        tables.append(Table(view: table, rowKey: rowKey))
        changed()
    }

    /// Rendered Markdown (`MarkdownView`): its stack and where its blocks
    /// are, each time they are measured.
    func sign(stack: NSView, frames: [Int: CGRect], scale: CGFloat, key: @escaping (Int) -> Int?,
              reveal: @escaping (Int) -> Void) {
        stacks.removeAll { $0.view == nil || $0.view === stack }
        stacks.append(Stack(view: stack, frames: frames, scale: scale, key: key, reveal: reveal))
        changed()
    }

    /// An image, or an SVG's picture (`ImagePreview`). Heard as a change
    /// only when the view is new.
    func sign(_ image: NSImageView) {
        images.removeAll { $0.view == nil }
        guard !images.contains(where: { $0.view === image }) else { return }
        images.append(Image(view: image))
        changed()
    }

    // MARK: - What the adapters read: the preview under the layer

    var table: NSTableView? { under(tables, \.view)?.view }
    var rowKey: (Int) -> Int? { under(tables, \.view)?.rowKey ?? { _ in nil } }

    var stack: NSView? { under(stacks, \.view)?.view }
    var blockFrames: [Int: CGRect] { under(stacks, \.view)?.frames ?? [:] }
    var blockScale: CGFloat { under(stacks, \.view)?.scale ?? 1 }
    var blockKey: (Int) -> Int? { under(stacks, \.view)?.key ?? { _ in nil } }
    func revealBlock(_ block: Int) { under(stacks, \.view)?.reveal(block) }

    var image: NSImageView? { under(images, \.view)?.view }

    /// Of the views signed in, the one under the layer: in its window, and
    /// where most of it is. With one, that one, which is every file shown
    /// once; with none in the layer's window (a layer not yet in one), the
    /// newest.
    private func under<Entry, View: NSView>(_ entries: [Entry], _ view: KeyPath<Entry, View?>) -> Entry? {
        // Asked for every mark on every scroll: the usual case, cheaply.
        if entries.count == 1, let only = entries.first { return only[keyPath: view] == nil ? nil : only }
        let live = entries.filter { $0[keyPath: view] != nil }
        guard live.count > 1, let layer, let window = layer.window else { return live.last }
        let over = layer.convert(layer.bounds, to: nil)
        var best: (entry: Entry, area: CGFloat)?
        for entry in live {
            guard let shown = entry[keyPath: view], shown.window === window else { continue }
            let common = shown.convert(shown.visibleRect, to: nil).intersection(over)
            let area = common.isNull ? 0 : common.width * common.height
            if area > 0, area >= best?.area ?? 0 { best = (entry, area) }
        }
        return best?.entry ?? live.last
    }

    // MARK: - Changes

    /// What is shown changed under the marks: a file rewritten, a block
    /// built or measured, the text resized.
    var onChange: () -> Void = {}

    func changed() { onChange() }

    /// The view shows nothing to mark any more (a diff emptied, a file
    /// cleared), and the views the marks were on are gone with it. Said
    /// rather than left to the weak references, which nothing announces:
    /// the layer stays over an emptied view and would go on drawing the
    /// marks where their lines were. A view that comes back signs in anew.
    func emptied() {
        tables = []
        stacks = []
        images = []
        changed()
    }
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
