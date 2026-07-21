import Foundation
import Observation

/// Drives the Markdown preview shown in the right inspector column. Holds the
/// currently-open file (its parsed blocks) and keeps it live: a coding agent
/// that rewrites the file has the preview re-render under it, via the same
/// FSEvents watcher the git panel uses.
///
/// One preview at a time — opening another file replaces it. Visibility isn't
/// stored here; the split controller shows the column while a document is open
/// (`onOpenChanged` nudges it) and the git panel takes the column back when the
/// preview closes.
@Observable
@MainActor
final class MarkdownPreviewModel {
    struct Document: Equatable {
        let url: URL
        let blocks: [MarkdownBlock]
        var name: String { url.lastPathComponent }
    }

    private(set) var document: Document?
    var isOpen: Bool { document != nil }

    /// Watches the open file's directory; a rewrite (agents replace the inode,
    /// so we watch the parent, not a file descriptor) re-reads and re-parses.
    @ObservationIgnored private var watcher: GitRepoWatcher?
    /// The file's modification time as last read, so a directory event for some
    /// *other* file — the common case when the preview sits in a busy repo — is
    /// dropped by a cheap stat before we pay for a read + parse.
    @ObservationIgnored private var lastModified: Date?

    /// Open `url` in the preview and start watching it for live updates.
    func open(_ url: URL) {
        let target = url.standardizedFileURL
        Task { await refresh(target) }
        watcher = GitRepoWatcher(root: target.deletingLastPathComponent().path) { [weak self] in
            DispatchQueue.main.async { self?.reload(target) }
        }
    }

    /// Close the preview, handing the column back to the git panel.
    func close() {
        guard isOpen else { return }
        document = nil
        watcher = nil
        lastModified = nil
    }

    private func reload(_ url: URL) {
        guard document?.url == url else { return }
        Task { await refresh(url) }
    }

    /// Read + parse the file off the main actor (a big document parsed on-main
    /// would freeze the terminal), then apply on-main. Skips work when *our* file
    /// hasn't moved (the watcher fires on any write in the directory), and — on a
    /// transient read failure, e.g. an event mid-rewrite — keeps the last good
    /// render rather than blanking the preview.
    private func refresh(_ url: URL) async {
        switch await Self.readAndParse(url, ifNewerThan: lastModified) {
        case .unchanged, .unreadable:
            return
        case .parsed(let blocks, let modified):
            lastModified = modified
            if document?.url != url || document?.blocks != blocks {
                document = Document(url: url, blocks: blocks)
            }
        }
    }

    private enum LoadResult {
        case parsed([MarkdownBlock], Date?)
        case unchanged
        case unreadable
    }

    /// Runs off the main actor (`nonisolated` async): stat first — a cheap way to
    /// drop directory events for other files — then read and parse only when the
    /// modification time moved.
    nonisolated private static func readAndParse(_ url: URL, ifNewerThan previous: Date?) async -> LoadResult {
        let modified = modificationDate(of: url)
        if let modified, let previous, modified == previous { return .unchanged }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        return .parsed(MarkdownParser.parse(text), modified)
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
