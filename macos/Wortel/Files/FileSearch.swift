import Foundation

/// The Files section of ⌘P: the matches for what's typed, in the folder of
/// the session you're in, ranked off the main thread so typing never waits.
///
/// The folder is the session's repository, or its folder outside one
/// (`FileIndexStore`). `foo.swift:120` and `foo.swift#L120` find
/// `foo.swift` and open it at line 120, as a ⌘-clicked path does
/// (`TerminalLink.withoutLocation`).
@Observable
@MainActor
final class FileSearchModel {
    struct Match: Identifiable, Equatable {
        /// Absolute.
        let path: String
        let name: String
        /// Its folder, relative to the one searched; empty at its top.
        let folder: String
        /// The git panel's letter for it, when it's changed.
        let status: Character?
        var id: String { "file-" + path }
    }

    private(set) var matches: [Match] = []
    /// Only part of the folder is listed (its walk reached the cap).
    private(set) var isPartial = false
    /// The answer to what's typed now isn't in yet: the ranking is running,
    /// or the folder's list is still being read. Return waits for it.
    private(set) var isPending = false

    @ObservationIgnored private let folder: FileIndexStore.Folder?
    @ObservationIgnored private let store: FileIndexStore
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var ranking: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The last ranking's query, index and survivors: a query that only adds
    /// to it searches those alone.
    @ObservationIgnored private var narrowing: (text: String, index: FileIndex, survivors: [Int32])?

    static let shownLimit = 50

    init(directory: String?, store: FileIndexStore? = nil) {
        let store = store ?? .shared
        self.store = store
        folder = directory.flatMap { store.folder(for: $0) }
        store.onChange = { [weak self] root in
            guard let self, root == folder?.root else { return }
            narrowing = nil
            rank()
        }
    }

    func search(_ query: String) {
        text = query
        if let folder { store.touch(folder) }
        rank()
    }

    private func rank() {
        ranking?.cancel()
        generation += 1
        let location = TerminalLink.withoutLocation(text.trimmingCharacters(in: .whitespaces)).path
        guard let folder, !location.isEmpty else {
            show([], partial: false, pending: false, for: generation)
            return
        }
        isPending = true
        let index = folder.index
        let root = folder.root
        let among = narrowing.flatMap { last in
            last.index === index && location.hasPrefix(last.text) ? last.survivors : nil
        }
        // What the person is likely after: changed here, opened lately.
        var weights: [String: Int32] = [:]
        for (path, weight) in RecentFiles.shared.weights(under: root) {
            weights[path, default: 0] += Int32(min(24, 8 * weight))
        }
        var statuses: [String: Character] = [:]
        if let status = store.knownStatus?(root)?.status {
            for change in status.changes {
                statuses[change.path] = change.statusCode
                weights[change.path, default: 0] += 16
            }
        }
        let (generation, partial, loading) = (generation, folder.isPartial, folder.isLoading)
        let limit = Self.shownLimit
        ranking = Task.detached(priority: .userInitiated) { [weak self] in
            var boosts: [Int32: Int32] = [:]
            for (path, weight) in weights {
                let bytes = Array(path.utf8)
                if let found = index.range(withPrefix: bytes).first(where: { Int(index.lengths[$0]) == bytes.count }) {
                    boosts[Int32(found)] = weight
                }
            }
            let result = FileMatch.rank(FileMatch.Query(location), in: index, among: among, limit: limit,
                                        boosts: boosts, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            let matches = result.matches.map { match in
                let relative = index.path(Int(match.index))
                let name = (relative as NSString).lastPathComponent
                let folder = (relative as NSString).deletingLastPathComponent
                return Match(path: (root as NSString).appendingPathComponent(relative), name: name,
                             folder: folder,
                             status: statuses[relative] ?? (index.kinds[Int(match.index)] == .untracked ? "?" : nil))
            }
            await self?.ranked(matches, survivors: result.survivors, text: location, index: index,
                               partial: partial, pending: loading, for: generation)
        }
    }

    private func ranked(_ matches: [Match], survivors: [Int32], text: String, index: FileIndex,
                        partial: Bool, pending: Bool, for generation: Int) {
        guard generation == self.generation else { return }
        narrowing = (text, index, survivors)
        show(matches, partial: partial, pending: pending, for: generation)
    }

    /// `pending`: ranked against a list still being read (the next one
    /// arrives with `onChange`).
    private func show(_ matches: [Match], partial: Bool, pending: Bool, for generation: Int) {
        guard generation == self.generation else { return }
        if self.matches != matches { self.matches = matches }
        isPartial = partial
        isPending = pending
    }
}
