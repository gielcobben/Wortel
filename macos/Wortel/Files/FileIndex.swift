import Foundation

/// Every file ⌘P can find in one folder, laid out for matching: one
/// contiguous buffer of path bytes, and per path where it starts, how long it
/// is, where its file name starts, and which letters it holds.
///
/// Built off the main thread and never changed: an update builds a new one
/// and swaps it in, so a search running on the old one is never disturbed.
/// Paths are relative to the folder, `/`-separated, in byte order (git's
/// order), each once.
///
/// A 500k-file monorepo is about 30 MB here, against about 50 bytes a path of
/// the paths themselves. `FileMatch` reads it; `FileIndexStore` keeps one per
/// folder.
final class FileIndex: Sendable {
    /// Where a path came from. A tracked file is in git's index; an
    /// untracked one is on disk and not ignored; a walked one was found by
    /// walking a folder that isn't a repository.
    enum Kind: UInt8, Sendable {
        case tracked, untracked, walked
    }

    let bytes: [UInt8]
    let starts: [Int32]
    let lengths: [Int32]
    /// Where the file name starts, from the path's own start.
    let nameStarts: [Int32]
    /// The letters in the path (`FileIndex.mask`), for a cheap "has every
    /// letter of the query" before any scoring.
    let masks: [UInt64]
    let kinds: [Kind]

    var count: Int { starts.count }

    static let empty = FileIndex(entries: [])

    /// From entries already sorted in byte order with no repeats.
    init(entries: [(path: ArraySlice<UInt8>, kind: Kind)]) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entries.reduce(0) { $0 + $1.path.count })
        var starts: [Int32] = [], lengths: [Int32] = [], nameStarts: [Int32] = []
        var masks: [UInt64] = [], kinds: [Kind] = []
        starts.reserveCapacity(entries.count)
        lengths.reserveCapacity(entries.count)
        nameStarts.reserveCapacity(entries.count)
        masks.reserveCapacity(entries.count)
        kinds.reserveCapacity(entries.count)
        for (path, kind) in entries {
            starts.append(Int32(bytes.count))
            lengths.append(Int32(path.count))
            var mask: UInt64 = 0
            var name = 0
            for (offset, byte) in path.enumerated() {
                mask |= Self.bit(byte)
                if byte == UInt8(ascii: "/") { name = offset + 1 }
            }
            bytes.append(contentsOf: path)
            nameStarts.append(Int32(name))
            masks.append(mask)
            kinds.append(kind)
        }
        self.bytes = bytes
        self.starts = starts
        self.lengths = lengths
        self.nameStarts = nameStarts
        self.masks = masks
        self.kinds = kinds
    }

    /// The path at `index`, as a string.
    func path(_ index: Int) -> String {
        let start = Int(starts[index])
        return String(decoding: bytes[start..<start + Int(lengths[index])], as: UTF8.self)
    }

    func pathBytes(_ index: Int) -> ArraySlice<UInt8> {
        let start = Int(starts[index])
        return bytes[start..<start + Int(lengths[index])]
    }

    /// The paths that start with `prefix`, which in byte order are next to
    /// each other: a folder's contents are `range(withPrefix: "folder/")`.
    func range(withPrefix prefix: [UInt8]) -> Range<Int> {
        func lowerBound(_ isBefore: (ArraySlice<UInt8>) -> Bool) -> Int {
            var low = 0, high = count
            while low < high {
                let mid = (low + high) / 2
                if isBefore(pathBytes(mid)) { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let lower = lowerBound { Self.compare($0, prefix[...]) < 0 }
        let upper = lowerBound { path in
            let head = path.prefix(prefix.count)
            return Self.compare(head, prefix[...]) <= 0
        }
        return lower..<max(lower, upper)
    }

    /// Whether `path` is in the index.
    func contains(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        let range = range(withPrefix: bytes)
        return range.contains { Int(lengths[$0]) == bytes.count }
    }

    // MARK: - Building

    /// A new index from sorted lists, merged in byte order. A path in more
    /// than one list is kept once, from the first list that has it: tracked
    /// before untracked, so a file just added to git stops being "new".
    static func merging(_ lists: [(paths: [ArraySlice<UInt8>], kind: Kind)]) -> FileIndex {
        var cursors = Array(repeating: 0, count: lists.count)
        var entries: [(path: ArraySlice<UInt8>, kind: Kind)] = []
        entries.reserveCapacity(lists.reduce(0) { $0 + $1.paths.count })
        while true {
            var best: Int?
            for (list, cursor) in cursors.enumerated() where cursor < lists[list].paths.count {
                guard let current = best else { best = list; continue }
                if compare(lists[list].paths[cursor], lists[current].paths[cursors[current]]) < 0 {
                    best = list
                }
            }
            guard let list = best else { break }
            let path = lists[list].paths[cursors[list]]
            // Skip this path in every list (a repeat in the same list too:
            // git lists a conflicted file once per stage).
            for other in lists.indices {
                while cursors[other] < lists[other].paths.count,
                      compare(lists[other].paths[cursors[other]], path) == 0 {
                    cursors[other] += 1
                }
            }
            entries.append((path, lists[list].kind))
        }
        return FileIndex(entries: entries)
    }

    /// `git ls-files -z` output split into paths, sorted in byte order.
    /// Git's own order already is; it's checked rather than trusted.
    static func split(nulSeparated data: [UInt8]) -> [ArraySlice<UInt8>] {
        var paths = data.split(separator: 0, omittingEmptySubsequences: true)
        if !isSorted(paths) { paths.sort { compare($0, $1) < 0 } }
        return paths
    }

    static func sorted(_ paths: some Collection<String>) -> [ArraySlice<UInt8>] {
        paths.map { Array($0.utf8)[...] }.sorted { compare($0, $1) < 0 }
    }

    private static func isSorted(_ paths: [ArraySlice<UInt8>]) -> Bool {
        var index = 1
        while index < paths.count {
            if compare(paths[index - 1], paths[index]) > 0 { return false }
            index += 1
        }
        return true
    }

    /// Byte order, as git sorts its index.
    static func compare(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        let common = min(a.count, b.count)
        guard common > 0 else { return a.count - b.count }
        let result = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in memcmp(pa.baseAddress!, pb.baseAddress!, common) }
        }
        return result == 0 ? a.count - b.count : Int(result)
    }

    // MARK: - Letters

    /// One bit per letter a path holds, case folded: a to z, then digits,
    /// then the rest shared out over what's left. A path can only match a
    /// query whose bits it all has.
    @inline(__always)
    static func bit(_ byte: UInt8) -> UInt64 {
        let lower = byte | (byte >= 65 && byte <= 90 ? 0x20 : 0)
        switch lower {
        case 97...122: return 1 << UInt64(lower - 97)
        case 48...57: return 1 << UInt64(26 + lower - 48)
        default: return 1 << UInt64(36 + lower % 28)
        }
    }

    static func mask(_ bytes: some Sequence<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 | bit($1) }
    }
}
