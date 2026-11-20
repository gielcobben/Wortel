import Foundation
import Observation

/// A height the person dragged a divider to, kept across launches.
///
/// In defaults, but not through `@AppStorage`. A view with an `@AppStorage`
/// property is told about *every* write to defaults, whatever the key, and
/// starts a transaction for each: its hosting view is marked for layout and
/// laid out again. AppKit writes to defaults at every step of a window
/// resize (the window's frame and the split view's dividers are both
/// autosaved), so the source-control panel, which kept its list's height
/// that way, was laid out at every step of every resize for a value nobody
/// was changing. Caught with the window on screen by logging who asked its
/// hosting view for layout: `UserDefaultObserver.noteChange`, 57 times in a
/// round of 240 steps (2026-11-19).
///
/// One object per height, so two panes showing the same list stay in step,
/// and a view that reads `value` is told when that one value changes.
@Observable
final class StoredHeight {
    /// The changes list in the source-control pane; the diff has the rest.
    static let changesList = StoredHeight(key: "git.listHeight", fallback: 200)
    /// The commit list in the history pane. Its own: the panes are read
    /// differently, so their splits shouldn't drag each other around.
    static let historyList = StoredHeight(key: "git.historyListHeight", fallback: 220)

    @ObservationIgnored private let key: String

    var value: Double {
        didSet {
            guard value != oldValue else { return }
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private init(key: String, fallback: Double) {
        self.key = key
        value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}
