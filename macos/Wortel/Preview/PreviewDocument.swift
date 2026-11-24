import AppKit
import Observation

/// The file behind one preview window: what it contains, in whichever way the
/// window is currently showing it, and keeping that true while an agent rewrites
/// it underneath.
///
/// The watching is `MarkdownPreviewModel`'s, generalised — that model solved this
/// hazard first and every part of its reasoning is load-bearing:
///
/// - **Watch the file *and* its directory, and never the subtree.** A vnode
///   watch follows an inode, and an agent saving a file replaces it (write temp,
///   rename over): the watch on the old inode reports the unlink and then goes
///   deaf, and a preview that stopped updating looks exactly like a file nobody
///   is touching. So the file's own watch reports in-place writes and re-arms
///   itself when it dies, and one watch on the containing directory notices the
///   file coming back. Not `GitRepoWatcher`: FSEvents is always recursive, so a
///   README previewed at a repo root would watch the entire repo — `.git`,
///   `node_modules` and all — which is the same mistake the file tree documents
///   not making.
/// - **Stat before reading.** The directory fires for every file in it, and in a
///   repo an agent is working through, that is constantly. A modification date
///   that hasn't moved costs a stat instead of a read, a decode and a parse.
/// - **Keep the last good content.** A read landing mid-rewrite fails or returns
///   half a file; blanking the window for a moment is worse than being one
///   revision stale for one.
///
/// Each mode's content is loaded on demand and thrown away together when the
/// file moves, so a window costs one mode's worth of work rather than three.
@Observable
@MainActor
final class PreviewDocument {
    /// The file this document is for. Canonical (symlinks resolved), because it
    /// is also the identity a window is looked up by.
    let url: URL
    /// The path the window was *asked* for, before symlinks were resolved. `url`
    /// is canonical because it's the identity a window is looked up by — but a
    /// file reached through an alias is worth saying out loud, since what you
    /// edit is the target and the tree gave no hint of it.
    let requestedURL: URL
    /// Where this window's diff comes from; `.none` outside a repo. Changed
    /// only by `retarget`: the same file's row on the other side of Changes.
    private(set) var diffSource: PreviewDiffSource
    /// Bumped by `retarget`, so a diff still loading for the old side is
    /// dropped when it lands.
    @ObservationIgnored private var diffGeneration = 0

    /// What the window is showing. Set by its toolbar; loads on demand.
    var mode: PreviewMode {
        didSet {
            guard mode != oldValue else { return }
            // Keep the reader's place. The outgoing view has been reporting the
            // source line at its top, and that line is the one coordinate all
            // three modes share — the rendered document, the file and the diff
            // are the same file seen three ways. Without it, ⌘2 to copy the
            // paragraph you were reading means finding it again from the top.
            // The line only: how far into its row or block the view was is a
            // distance in the outgoing view, and means nothing in the next.
            anchorLine = visibleLine
            anchorOffset = 0
            visibleOffset = 0
            selectedLine = nil
            selectsAll = false
            loadCurrentMode()
        }
    }

    /// The source line at the top of whatever view is on screen, kept current by
    /// that view. Deliberately unobserved: it changes on every scroll frame, and
    /// nothing draws from it — it's read when the mode changes and when a tab
    /// is shown again.
    @ObservationIgnored var visibleLine = 1
    /// How far past the top of that line's row or block the view is scrolled,
    /// in points. A line is as close as a mode switch can get, but coming back
    /// to a tab is the same view again, and a paragraph's height short of
    /// where you were reads as "not quite where I left it".
    @ObservationIgnored var visibleOffset: CGFloat = 0
    /// Where the incoming view should scroll to: after a mode switch, and when
    /// a tab is shown again (`PreviewTab`). Unobserved for the same reason it
    /// doesn't need to be: both rebuild the view that reads it.
    @ObservationIgnored var anchorLine: Int?
    /// How far past the anchor line's top to land; see `visibleOffset`.
    @ObservationIgnored var anchorOffset: CGFloat = 0

    /// A line someone asked to see: a ⌘-clicked `App.swift:42` in a terminal.
    /// Unlike the anchor, which a view takes once on arriving, this is for the
    /// view already on screen too, so it is observed, carries a serial (the
    /// same line asked for twice is two requests), and the view that shows it
    /// hands it back (`revealDone`), so a view rebuilt later (a session
    /// switch) opens where the reader is rather than on an old request.
    struct LineReveal: Equatable {
        let line: Int
        let serial: Int
    }
    private(set) var lineReveal: LineReveal?
    @ObservationIgnored private var revealSerial = 0

    /// Show `line`: scrolled to and selected. A diff shows only the lines
    /// that changed, so the line asked for is usually not in it: a diff gives
    /// way to the file. Rendered Markdown stays rendered and lands on the
    /// block holding the line, which is the same place, readable.
    func reveal(line: Int) {
        if mode == .diff, availableModes.contains(.source) { mode = .source }
        // Also the place a view built from now on opens at: the tab copies
        // its last place into the anchor when it is built.
        visibleLine = line
        visibleOffset = 0
        anchorLine = line
        anchorOffset = 0
        revealSerial += 1
        lineReveal = LineReveal(line: line, serial: revealSerial)
    }

    /// The line selected in Source or Diff, reported by the view; nil when
    /// none is, and in Rendered, which has no lines to select.
    @ObservationIgnored var selectedLine: Int?

    /// The line "Open in <editor>" opens at: the one you selected, else the
    /// one at the top of what you're reading.
    var lineForEditor: Int { selectedLine ?? visibleLine }

    /// The view has shown `reveal`. A later request is left alone.
    func revealDone(_ reveal: LineReveal) {
        if lineReveal == reveal { lineReveal = nil }
    }

    /// Select All, for the one mode that can't do it itself. Source and Diff are
    /// a table: they select rows natively and copy them. A rendered document is a
    /// stack of separate SwiftUI `Text` views, and SwiftUI selects *within* one —
    /// a drag stops dead at a heading — so "select everything" is a state the
    /// document holds and the view draws. To copy prose out properly, ⌘2 to the
    /// source: it's the same file, in a view built for selecting.
    var selectsAll = false

    // MARK: What each mode draws

    private(set) var sourceLines: [DiffLine] = []
    private(set) var sourceHighlights: [Int: [HighlightSpan]] = [:]
    private(set) var sourceTruncated = false

    private(set) var diffLines: [DiffLine] = []
    private(set) var diffHighlights: [Int: [HighlightSpan]] = [:]
    private(set) var diffTruncated = false
    private(set) var diffIsBinary = false
    /// Distinguishes "no changes" from "not asked yet", so the window doesn't
    /// flash an empty state on its way to a diff.
    private(set) var diffLoaded = false

    private(set) var blocks: [MarkdownBlock] = []

    /// Not text we can show — an image, a binary. The window hands these to
    /// Quick Look, which knows more formats than we ever will.
    private(set) var isBinary = false
    /// Bumped whenever the content is replaced. Views that read the file
    /// themselves — the image preview — redraw on this rather than on every
    /// SwiftUI update, since a find-bar keystroke re-renders the window and
    /// decoding a screenshot per keypress is real work.
    private(set) var contentVersion = 0
    /// The file is gone from disk. The content stays on screen (it's still worth
    /// reading, and a branch switch may well bring it back); the window says so,
    /// and clears this the moment it returns.
    private(set) var isMissing = false

    /// The document as plain text, for Copy: the file itself, which is what a
    /// rendered preview is a rendering *of*.
    var plainText: String {
        sourceLines.map(\.text).joined(separator: "\n")
    }

    var availableModes: [PreviewMode] {
        PreviewMode.available(for: url, hasDiffSource: diffSource.exists)
    }

    /// Big enough for any file worth reading in a preview, small enough that a
    /// stray 100MB log can't hitch the app. Lines rather than bytes: lines are
    /// what the renderer actually pays for.
    ///
    /// `nonisolated` because `read(_:ifNewerThan:parseMarkdown:)` is, and has to
    /// be — it touches the disk and must never run on the main actor. Two
    /// immutable numbers have nothing to isolate.
    nonisolated static let maxLines = 20_000
    nonisolated static let maxBytes = 8 * 1024 * 1024

    @ObservationIgnored private let highlighter: (any DiffHighlighting)?
    @ObservationIgnored private var fileWatcher: DirectoryWatcher?
    @ObservationIgnored private var directoryWatcher: DirectoryWatcher?
    @ObservationIgnored private var lastModified: Date?
    /// Rising token, so a slow read or highlight for a previous revision can't
    /// land on top of a newer one.
    @ObservationIgnored private var revision = 0

    /// The file is an alias, and `url` is where it really is.
    var isAlias: Bool { requestedURL != url }

    init(url: URL,
         diffSource: PreviewDiffSource = .none,
         mode: PreviewMode = .source,
         highlighter: (any DiffHighlighting)? = nil) {
        self.requestedURL = url.standardizedFileURL
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        self.diffSource = diffSource
        self.mode = mode
        self.highlighter = highlighter
        reload()
        watchFile()
        // The directory's only job is the file coming *back* — deleted and
        // rewritten, or restored by a branch switch — because at that moment
        // there is no file watch left to fire.
        directoryWatcher = DirectoryWatcher(path: self.url.deletingLastPathComponent().path) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.fileWatcher == nil else { return }
                self.watchFile()
                self.reload()
            }
        }
    }

    /// Watch the file itself for in-place writes, and re-arm when it is replaced
    /// — a rename over the top unlinks the inode this is watching, which arrives
    /// as `vanished` and is the last thing this watch will ever say.
    private func watchFile() {
        fileWatcher = DirectoryWatcher(path: url.path) { [weak self] vanished in
            Task { @MainActor in
                guard let self else { return }
                if vanished {
                    self.fileWatcher = nil
                    self.watchFile()
                }
                self.reload()
            }
        }
    }

    /// The file may have moved. Safe to call on every directory event — the stat
    /// inside is the point.
    func reload() {
        let url = self.url
        let previous = lastModified
        let wantsMarkdown = PreviewMode.isMarkdown(url)
        revision += 1
        let token = revision
        Task { [weak self] in
            let result = await Self.read(url, ifNewerThan: previous, parseMarkdown: wantsMarkdown)
            guard let self, token == self.revision else { return }
            self.apply(result, token: token)
        }
    }

    private func apply(_ result: LoadResult, token: Int) {
        switch result {
        case .unchanged:
            if isMissing { isMissing = false }
        case .missing:
            // Content stays; only the mark changes.
            if !isMissing { isMissing = true }
        case .binary(let modified):
            contentVersion += 1
            lastModified = modified
            isMissing = false
            isBinary = true
            sourceLines = []
            sourceHighlights = [:]
        case .text(let lines, let markdown, let modified, let truncated):
            contentVersion += 1
            lastModified = modified
            isMissing = false
            isBinary = false
            sourceTruncated = truncated
            sourceLines = lines
            sourceHighlights = [:]
            blocks = markdown
            // The file moved, so whatever diff we had described the old one.
            diffLoaded = false
            diffLines = []
            diffHighlights = [:]
            highlight(lines, token: token) { $0.sourceHighlights = $1 }
            loadCurrentMode()
        }
    }

    /// Only the mode on screen does any work. Switching to one that hasn't been
    /// loaded loads it then; switching back costs nothing.
    private func loadCurrentMode() {
        guard mode == .diff, !diffLoaded, !isBinary else { return }
        loadDiff()
    }

    // MARK: - Diff

    /// Show the diff from `source` instead: the same file, from its row on
    /// the other side of the Changes list (staged, then not). The file itself
    /// is unchanged, so only the diff is loaded again.
    func retarget(_ source: PreviewDiffSource) {
        guard source != diffSource else { return }
        diffSource = source
        diffGeneration += 1
        diffLoaded = false
        diffLines = []
        diffHighlights = [:]
        loadCurrentMode()
    }

    private func loadDiff() {
        let source = diffSource
        guard source.exists else { return }
        let token = revision
        let generation = diffGeneration
        Task { [weak self] in
            // Both the git call *and* the parse happen off the main actor. A
            // `Task {}` started here would otherwise inherit this class's
            // isolation and parse on the main thread — which is the exact freeze
            // the git panel documents: a regenerated lock file's 51MB patch took
            // 1.2s, terminal included.
            let parsed = await Self.parsedPatch(for: source)
            guard let self, token == self.revision, generation == self.diffGeneration else { return }
            self.diffLines = parsed.lines
            self.diffIsBinary = parsed.isBinary
            self.diffTruncated = parsed.truncated
            self.diffHighlights = [:]
            self.diffLoaded = true
            self.highlight(parsed.lines, token: token) { $0.diffHighlights = $1 }
        }
    }

    nonisolated private static func parsedPatch(for source: PreviewDiffSource) async -> DiffResult {
        DiffParser.parse(await patch(for: source))
    }

    nonisolated private static func patch(for source: PreviewDiffSource) async -> String {
        switch source {
        case .none:
            return ""
        case .workingTree(let root, let path, let untracked):
            return untracked
                ? await GitService.untrackedDiff(root: root, path: path)
                : await GitService.diffAgainstHead(root: root, path: path)
        case .change(let root, let change):
            return await GitService.diff(root: root, change: change)
        case .commit(let root, let sha, let path, let originalPath):
            return await GitService.commitFileDiff(
                root: root, sha: sha, path: path, originalPath: originalPath)
        }
    }

    // MARK: - Highlighting

    /// Colour arrives after the text. tree-sitter is fast but it is not free,
    /// and a file you can already read is worth more than one you can't yet.
    private func highlight(_ lines: [DiffLine], token: Int,
                           apply: @escaping (PreviewDocument, [Int: [HighlightSpan]]) -> Void) {
        guard let highlighter, !lines.isEmpty else { return }
        Task { [weak self] in
            let spans = await highlighter.highlight(lines)
            guard let self, token == self.revision else { return }
            apply(self, spans)
        }
    }

    // MARK: - Reading (off the main actor)

    /// Internal, with `read`, so the tests can name what they got back.
    enum LoadResult {
        case text([DiffLine], [MarkdownBlock], Date?, Bool)
        case binary(Date?)
        case unchanged
        case missing
    }

    /// Reads and splits the file. `nonisolated` and static: this touches the
    /// disk, and the terminal must not wait on a slow volume. Internal rather
    /// than private so `PreviewDocumentTests` can hand it a real file — it is
    /// the whole of what a preview shows, and every one of its edge cases fails
    /// quietly.
    nonisolated static func read(
        _ url: URL, ifNewerThan previous: Date?, parseMarkdown: Bool
    ) async -> LoadResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        let modified = attributes[.modificationDate] as? Date
        if let modified, let previous, modified == previous { return .unchanged }

        // The size cap comes *before* the read, which is the only place it can do
        // any good: checking it afterwards still pulls the whole file into memory
        // first, so a stray 2GB log allocated 2GB on its way to being rejected.
        let size = (attributes[.size] as? Int) ?? 0
        guard size <= maxBytes else { return .binary(modified) }
        // Deliberately not `.mappedIfSafe`: these files are being rewritten by
        // agents, and a mapped file truncated under us faults the whole app. The
        // size cap is what makes a plain read affordable.
        guard let data = try? Data(contentsOf: url) else { return .missing }
        // A NUL in the first stretch is how `git` itself calls a file binary, and
        // it answers the only question the window has: can this be shown as lines
        // of text?
        if data.prefix(8_000).contains(0) { return .binary(modified) }
        guard let text = String(data: data, encoding: .utf8) else { return .binary(modified) }

        var split = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline ends the file; it isn't a final empty line.
        if split.last?.isEmpty == true { split.removeLast() }
        let truncated = split.count > maxLines
        if truncated { split = Array(split.prefix(maxLines)) }

        let path = url.path
        let lines = split.enumerated().map { index, line in
            DiffLine(id: index, kind: .context, text: String(line),
                     oldLine: index + 1, newLine: index + 1, path: path)
        }
        let blocks = parseMarkdown ? MarkdownParser.parse(text) : []
        return .text(lines, blocks, modified, truncated)
    }
}
