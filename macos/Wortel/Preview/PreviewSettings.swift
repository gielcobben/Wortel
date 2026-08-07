import AppKit
import Observation

/// How previews are drawn, shared by every preview window and remembered.
///
/// App-wide rather than per window on purpose: you set a reading size once for
/// your screen and your eyes, not per file. It's the same reasoning as the
/// remembered window size — and it means ⌘+ in one window resizes the text in
/// all of them, which is what "the preview's font size" means when there are
/// three of them open.
@Observable
@MainActor
final class PreviewSettings {
    /// A touch larger than the inspector's diff. That pane is a column beside a
    /// terminal, where density is the point; a preview window is something you
    /// opened *to read*, and it has the room.
    static let defaultFontSize: CGFloat = 13
    /// Small enough to skim a wide file, large enough to read across the room.
    static let range: ClosedRange<CGFloat> = 9...24

    var fontSize: CGFloat {
        didSet {
            let clamped = min(max(fontSize, Self.range.lowerBound), Self.range.upperBound)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            UserDefaults.standard.set(Double(fontSize), forKey: Self.key)
        }
    }

    private static let key = "preview.fontSize"

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        fontSize = Self.range.contains(stored) ? stored : Self.defaultFontSize
    }

    /// One point a step, like every text size on the platform.
    func increase() { fontSize += 1 }
    func decrease() { fontSize -= 1 }
    func reset() { fontSize = Self.defaultFontSize }
}
