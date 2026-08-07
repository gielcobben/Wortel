import AppKit
import Observation

/// The file behind one preview window: what it contains, and keeping that true
/// while an agent rewrites it underneath.
///
/// The watching here is `MarkdownPreviewModel`'s, generalised — that model
/// already solved this hazard and its reasoning is worth restating, because
/// every part of it is load-bearing:
///
/// - **Watch the parent directory, not the file.** A vnode watch follows an
///   inode, and an agent saving a file replaces it (write temp, rename over).
///   A watch on the file's own descriptor dies on the first save and reports
///   nothing ever again — and a preview that stopped updating looks exactly like
///   a file nobody is touching.
/// - **Stat before reading.** The directory fires for every file in it, and in a
///   repo an agent is working through that is constantly. A modification date
///   that hasn't moved costs a stat instead of a read, a decode and a parse.
/// - **Keep the last good content.** A read landing mid-rewrite fails or returns
///   half a file; blanking the window for a moment is worse than being one
///   revision stale for one moment.
@Observable
@MainActor
final class PreviewDocument {
    /// The file this document is for. Canonical (symlinks resolved), because it
    /// is also the identity a window is looked up by.
    let url: URL

    /// The file's lines, as an all-context diff — which is what `DiffView`
    /// draws and what `DiffHighlighting` highlights, so Source mode needs
    /// neither its own renderer nor its own highlighting path.
    private(set) var lines: [DiffLine] = []
    /// Syntax spans by line id, filled in after the first paint so the window
    /// shows text immediately and colours a moment later.
    private(set) var highlights: [Int: [HighlightSpan]] = [:]
    /// Set when the file was too big to show in full, so the window can say so
    /// rather than implying the file simply ends there.
    private(set) var truncated = false
    /// Not text we can show — an image, a binary. The window hands these to
    /// Quick Look, which knows more formats than we ever will.
    private(set) var isBinary = false
    /// The file is gone from disk. The content stays on screen (it's still
    /// worth reading, and a branch switch may well bring it back); the window
    /// says so, and clears this the moment it returns.
    private(set) var isMissing = false

    /// Big enough for any file worth reading in a preview, small enough that a
    /// stray 100MB log can't hitch the app. Lines rather than bytes: it's what
    /// the renderer actually pays for.
    static let maxLines = 20_000
    static let maxBytes = 8 * 1024 * 1024

    @ObservationIgnored private let highlighter: (any DiffHighlighting)?
    @ObservationIgnored private var watcher: GitRepoWatcher?
    @ObservationIgnored private var lastModified: Date?
    /// Rising token, so a slow highlight for a previous revision can't land on
    /// top of a newer one.
    @ObservationIgnored private var revision = 0

    init(url: URL, highlighter: (any DiffHighlighting)? = nil) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        self.highlighter = highlighter
        load()
        watcher = GitRepoWatcher(root: self.url.deletingLastPathComponent().path) { [weak self] in
            Task { @MainActor in self?.load() }
        }
    }

    /// Re-read if the file actually moved. Safe to call on every directory
    /// event — the stat is the point.
    func load() {
        let url = self.url
        let previous = lastModified
        revision += 1
        let token = revision
        Task { [weak self] in
            let result = await Self.read(url, ifNewerThan: previous)
            guard let self, token == self.revision else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: LoadResult) {
        switch result {
        case .unchanged:
            if isMissing { isMissing = false }
        case .missing:
            // Content stays. Only the mark changes.
            if !isMissing { isMissing = true }
        case .binary(let modified):
            lastModified = modified
            isMissing = false
            isBinary = true
            lines = []
            highlights = [:]
        case .text(let newLines, let modified, let wasTruncated):
            lastModified = modified
            isMissing = false
            isBinary = false
            truncated = wasTruncated
            lines = newLines
            highlights = [:]
            highlight(newLines, token: revision)
        }
    }

    /// Colour arrives after the text. tree-sitter is fast but it is not free,
    /// and a file you can already read is worth more than one you can't yet.
    private func highlight(_ lines: [DiffLine], token: Int) {
        guard let highlighter, !lines.isEmpty else { return }
        Task { [weak self] in
            let spans = await highlighter.highlight(lines)
            guard let self, token == self.revision else { return }
            self.highlights = spans
        }
    }

    // MARK: - Reading (off the main actor)

    private enum LoadResult {
        case text([DiffLine], Date?, Bool)
        case binary(Date?)
        case unchanged
        case missing
    }

    /// Reads and splits the file. `nonisolated` and static: this touches the
    /// disk, and the terminal must not wait on a slow volume.
    nonisolated private static func read(_ url: URL, ifNewerThan previous: Date?) async -> LoadResult {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else { return .missing }
        let modified = attributes[.modificationDate] as? Date
        if let modified, let previous, modified == previous { return .unchanged }

        let size = (attributes[.size] as? Int) ?? 0
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .missing }
        // A NUL in the first stretch is how `git` itself calls a file binary,
        // and it's the cheap answer for the question the window actually asks:
        // can this be shown as lines of text?
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
        return .text(lines, modified, truncated)
    }
}
