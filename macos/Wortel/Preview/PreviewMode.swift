import Foundation

/// What a preview window is showing a file *as*.
///
/// Pure and separate from the window so the one rule with a wrong answer — which
/// mode a file opens on — can be checked without an app around it.
enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
    /// The file itself, syntax highlighted.
    case source
    /// What changed in it: the working tree against HEAD, one Changes row, or
    /// one commit — decided by where the window was opened from.
    case diff
    /// Markdown, typeset.
    case rendered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .diff: return "Diff"
        case .rendered: return "Rendered"
        }
    }

    /// Matched to the inspector's own pane control, so the two toolbars read as
    /// one vocabulary rather than two.
    var symbol: String {
        switch self {
        case .source: return "doc.text"
        case .diff: return "plusminus"
        case .rendered: return "doc.richtext"
        }
    }

    /// Which modes a file can offer. Rendered only for Markdown, Diff only when
    /// the window was opened somewhere that *has* a diff to show — outside a
    /// repo there is no such question to ask.
    static func available(for url: URL, hasDiffSource: Bool) -> [PreviewMode] {
        var modes: [PreviewMode] = [.source]
        if hasDiffSource { modes.insert(.diff, at: 0) }
        if isMarkdown(url) { modes.insert(.rendered, at: 0) }
        return modes
    }

    /// The mode a window opens on, decided once and then left alone (the window
    /// is sticky afterwards — scrubbing a list must never move the toolbar under
    /// your hands).
    ///
    /// Markdown opens rendered because that's what you meant by opening it. A
    /// file with changes opens on its diff because the reason you reached for it
    /// is almost always what just happened to it. Everything else is source.
    static func inferred(for url: URL, hasChanges: Bool, hasDiffSource: Bool) -> PreviewMode {
        if isMarkdown(url) { return .rendered }
        if hasChanges, hasDiffSource { return .diff }
        return .source
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}

/// Where a preview window's diff comes from — set when the window is opened,
/// because the question differs by where you opened it from.
///
/// A Changes row means *that* row: the pane separates staged from unstaged, so a
/// window opened from one has to show the same side, or it quietly contradicts
/// the list you clicked in. The tree and a ⌘-clicked path have no such notion,
/// and there the question you're actually asking is "what's different from the
/// last commit".
enum PreviewDiffSource: Equatable {
    case none
    case workingTree(root: String, path: String)
    case change(root: String, change: GitFileChange)
    case commit(root: String, sha: String, path: String, originalPath: String?)

    var exists: Bool { self != .none }
}
