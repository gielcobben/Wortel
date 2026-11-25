import Foundation

/// Walking up a folder tree, written once, so that it always ends.
///
/// 2026.47.4 hung for good on a ⌘-clicked path outside any repository, on
/// macOS 15.5. The walk up to the repository root used
/// `URL.deletingLastPathComponent()` and stopped when the parent equalled the
/// folder, and there the parent of `/` is not `/`: it climbed `/..`,
/// `/../..` on the main thread until a force quit, 25 GB in
/// (`docs/incidents.md`, 2026-11-25). A walk that stops on a fixed point
/// trusts Foundation to have one; this one stops because every step is a
/// strictly shorter string, whatever the system says a parent is.
enum PathWalk {
    /// `path`, then each folder above it, nearest first: up to `/` for an
    /// absolute path, up to the first component for a relative one. Empty for
    /// an empty path. Pass it already standardized, as each caller wants it.
    static func upward(from path: String) -> [String] {
        var result: [String] = []
        var current = path
        while !current.isEmpty {
            result.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            guard parent.count < current.count else { break }
            current = parent
        }
        return result
    }
}
