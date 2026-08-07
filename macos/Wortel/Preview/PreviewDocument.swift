import AppKit
import Observation

/// The file behind one preview window: what it contains, in whichever way the
/// window is currently showing it, and keeping that true while an agent rewrites
/// it underneath.
///
/// The watching is `MarkdownPreviewModel`'s, generalised — that model solved this
/// hazard first and every part of its reasoning is load-bearing:
///
/// - **Watch the parent directory, not the file.** A vnode watch follows an
///   inode, and an agent saving a file replaces it (write temp, rename over). A
///   watch on the file's own descriptor dies on the first save and reports
///   nothing ever again — and a preview that stopped updating looks exactly like
///   a file nobody is touching.
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
    /// Where this window's diff comes from; `.none` outside a repo.
    let diffSource: PreviewDiffSource

    /// What the window is showing. Set by its toolbar; loads on demand.
    var mode: PreviewMode {
        didSet { if mode != oldValue { loadCurrentMode() } }
    }

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
    /// The file is gone from disk. The content stays on screen (it's still worth
    /// reading, and a branch switch may well bring it back); the window says so,
    /// and clears this the moment it returns.
    private(set) var isMissing = false

    var availableModes: [PreviewMode] {
        PreviewMode.available(for: url, hasDiffSource: diffSource.exists)
    }

    /// Big enough for any file worth reading in a preview, small enough that a
    /// stray 100MB log can't hitch the app. Lines rather than bytes: lines are
    /// what the renderer actually pays for.
    static let maxLines = 20_000
    static let maxBytes = 8 * 1024 * 1024

    @ObservationIgnored private let highlighter: (any DiffHighlighting)?
    @ObservationIgnored private var watcher: GitRepoWatcher?
    @ObservationIgnored private var lastModified: Date?
    /// Rising token, so a slow read or highlight for a previous revision can't
    /// land on top of a newer one.
    @ObservationIgnored private var revision = 0

    init(url: URL,
         diffSource: PreviewDiffSource = .none,
         mode: PreviewMode = .source,
         highlighter: (any DiffHighlighting)? = nil) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        self.diffSource = diffSource
        self.mode = mode
        self.highlighter = highlighter
        reload()
        watcher = GitRepoWatcher(root: self.url.deletingLastPathComponent().path) { [weak self] in
            Task { @MainActor in self?.reload() }
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
            lastModified = modified
            isMissing = false
            isBinary = true
            sourceLines = []
            sourceHighlights = [:]
        case .text(let lines, let markdown, let modified, let truncated):
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

    private func loadDiff() {
        let source = diffSource
        guard source.exists else { return }
        let token = revision
        Task { [weak self] in
            let patch = await Self.patch(for: source)
            let parsed = DiffParser.parse(patch)
            guard let self, token == self.revision else { return }
            self.diffLines = parsed.lines
            self.diffIsBinary = parsed.isBinary
            self.diffTruncated = parsed.truncated
            self.diffHighlights = [:]
            self.diffLoaded = true
            self.highlight(parsed.lines, token: token) { $0.diffHighlights = $1 }
        }
    }

    nonisolated private static func patch(for source: PreviewDiffSource) async -> String {
        switch source {
        case .none:
            return ""
        case .workingTree(let root, let path):
            return await GitService.diffAgainstHead(root: root, path: path)
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

    private enum LoadResult {
        case text([DiffLine], [MarkdownBlock], Date?, Bool)
        case binary(Date?)
        case unchanged
        case missing
    }

    /// Reads and splits the file. `nonisolated` and static: this touches the
    /// disk, and the terminal must not wait on a slow volume.
    nonisolated private static func read(
        _ url: URL, ifNewerThan previous: Date?, parseMarkdown: Bool
    ) async -> LoadResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        let modified = attributes[.modificationDate] as? Date
        if let modified, let previous, modified == previous { return .unchanged }

        let size = (attributes[.size] as? Int) ?? 0
        // Deliberately not `.mappedIfSafe`: these files are being rewritten by
        // agents, and a mapped file truncated under us faults the whole app. The
        // size cap is what makes a plain read affordable.
        guard let data = try? Data(contentsOf: url) else { return .missing }
        // A NUL in the first stretch is how `git` itself calls a file binary, and
        // it answers the only question the window has: can this be shown as lines
        // of text?
        if data.prefix(8_000).contains(0) { return .binary(modified) }
        guard size <= maxBytes, let text = String(data: data, encoding: .utf8) else {
            return .binary(modified)
        }

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
