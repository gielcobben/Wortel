import AppKit
import SwiftUI

/// A thin, draggable divider that resizes an adjacent pane by writing a bound
/// length (a width or a height). SwiftUI's `HSplitView`/`VSplitView` own their
/// divider positions and never expose them, so there's no way to persist where
/// the user dragged to. This replaces them: the length lives in a binding the
/// caller can persist, and the divider just clamps and updates it.
///
/// `axis` is the drag direction. `invert` flips the sign for panes that grow as
/// the pointer moves toward the origin — e.g. a trailing panel widens as the
/// divider is dragged left.
struct DragDivider: View {
    let axis: Axis
    @Binding var length: CGFloat
    let range: ClosedRange<CGFloat>
    var invert: Bool = false
    /// Whether the hairline is drawn. A divider pushed to the very edge of
    /// its pane (the Changes diff, hidden) is still there to drag, but drawn
    /// it would double the edge's own line.
    var showsLine: Bool = true
    /// The drag let go: for a pane that snaps shut past a point.
    var onEnded: (() -> Void)? = nil

    /// Length captured at gesture start, so translation is applied to a stable
    /// base rather than compounding each `onChanged`.
    @State private var start: CGFloat?
    @State private var hovering = false

    private var thickness: CGFloat { 1 }
    private var hitSlop: CGFloat { 10 }

    var body: some View {
        // A hairline divider with an invisible, wider hit area so it's easy to
        // grab without a visible fat bar.
        Rectangle()
            .fill(showsLine ? Color(nsColor: .separatorColor) : .clear)
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(
                        width: axis == .horizontal ? thickness + hitSlop * 2 : nil,
                        height: axis == .vertical ? thickness + hitSlop * 2 : nil
                    )
                    .onHover { inside in
                        hovering = inside
                        updateCursor(inside)
                    }
                    .gesture(drag)
            }
    }

    private var drag: some Gesture {
        // Measure in global space: the divider itself moves as the pane resizes,
        // and a local-space translation would be distorted by that movement each
        // frame — the feedback loop that shows up as jitter. Global space is
        // fixed to the screen, so translation stays a clean finger delta.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let base = start ?? length
                if start == nil { start = length }
                let raw = axis == .horizontal ? value.translation.width : value.translation.height
                let delta = invert ? -raw : raw
                length = min(max(base + delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                start = nil
                onEnded?()
            }
    }

    private func updateCursor(_ inside: Bool) {
        if inside {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
    }
}
