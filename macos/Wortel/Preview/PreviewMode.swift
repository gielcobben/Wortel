import Foundation
import UniformTypeIdentifiers

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

    /// The View ▸ Preview item that selects this mode, identified by tag rather
    /// than by menu position: the items are fixed, the modes a given file offers
    /// are not, so ⌘2 means "source" in every window rather than "whatever the
    /// second segment happens to be here".
    var menuTag: Int {
        switch self {
        case .diff: return 1
        case .source: return 2
        case .rendered: return 3
        }
    }

    static func mode(menuTag: Int) -> PreviewMode? {
        allCases.first { $0.menuTag == menuTag }
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

    /// Which modes a file can offer, in the order they're offered. Rendered only
    /// for Markdown, Diff only when the window was opened somewhere that *has* a
    /// diff to show — outside a repo there is no such question to ask.
    ///
    /// The order is Diff → Source → Rendered, and it's a scale rather than a
    /// list: each step is one further from the bytes on disk. Diff is the
    /// narrowest view (only what changed), Source is the whole file, Rendered is
    /// the file as something else entirely. Putting Rendered on the end also
    /// keeps the two views that *are* the same text side by side, so ⌘1/⌘2 flip
    /// between neighbours.
    static func available(for url: URL, hasDiffSource: Bool) -> [PreviewMode] {
        var modes: [PreviewMode] = []
        if hasDiffSource { modes.append(.diff) }
        modes.append(.source)
        if isRenderableText(url) { modes.append(.rendered) }
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
        if isRenderableText(url) { return .rendered }
        if hasChanges, hasDiffSource { return .diff }
        return .source
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    /// Text that is also a picture of something. Markdown is the obvious one; an
    /// SVG is the interesting one — it is a text file *and* an image, so it's the
    /// only kind of file where "show me the code" and "show me the thing" are
    /// both reasonable and neither is a fallback for the other. ⌘1/⌘2 between
    /// them is the whole feature.
    static func isRenderableText(_ url: URL) -> Bool {
        isMarkdown(url) || isSVG(url)
    }

    static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
    }

    /// Anything the system calls an image — PNG, JPEG, GIF, TIFF, HEIC, SVG.
    /// Asked of the *type* rather than a list of extensions kept up to date here.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
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
extension PreviewDiffSource {
    /// Whether two sources show the same diff of a file for the person
    /// reading it: only a Changes row's side (staged or not) tells them
    /// apart. A status code moving, or the same file reached from Files,
    /// is the same diff on screen.
    func showsSameSide(as other: PreviewDiffSource) -> Bool {
        if case .change(_, let a) = self, case .change(_, let b) = other { return a.staged == b.staged }
        return true
    }
}

enum PreviewDiffSource: Equatable {
    case none
    /// Everything since HEAD for one path. `untracked` because git can't diff a
    /// file it has never seen: `diff HEAD -- new.swift` prints nothing at all, so
    /// a brand-new file opened from the tree would show "No changes to this file"
    /// while sitting there full of changes. Untracked files diff against
    /// /dev/null instead, which is what the Changes list already does.
    case workingTree(root: String, path: String, untracked: Bool)
    case change(root: String, change: GitFileChange)
    case commit(root: String, sha: String, path: String, originalPath: String?)

    var exists: Bool { self != .none }
}
