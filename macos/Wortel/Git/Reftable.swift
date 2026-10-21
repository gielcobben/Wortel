import Foundation

/// Where HEAD points, read straight from a reftable stack: the ref store a
/// repository made with `git init --ref-format=reftable` (or migrated with
/// `git refs migrate`) keeps instead of loose files. Its HEAD file is only a
/// stub naming `refs/heads/.invalid`, so the instant no-git read of a
/// worktree's branch (`GitWorktree.checkedOutBranch`) has to look in here.
///
/// Only as much of the format as finding one ref needs
/// (git's Documentation/technical/reftable.txt): a stack is `tables.list`,
/// oldest first, each naming a table; a table is a header, then ref blocks of
/// prefix-compressed records sorted by name. A linked worktree's own stack
/// holds HEAD and the few refs per worktree (ORIG_HEAD, refs/bisect/…), and
/// git compacts it as it grows, so this reads one small file. Anything it
/// doesn't recognise is nil, and the caller falls back to asking git.
enum Reftable {
    /// The ref `name` points at as a symbolic ref (`refs/heads/main` for a
    /// HEAD on main), looked up in the stack at `dir` (a git dir's
    /// `reftable` folder), newest table first. nil when it's a plain object
    /// id (a detached HEAD), deleted, absent, or unreadable.
    nonisolated static func symbolicTarget(of name: String, inStack dir: String) -> String? {
        guard let list = try? String(contentsOfFile: (dir as NSString).appendingPathComponent("tables.list"),
                                     encoding: .utf8) else { return nil }
        let key = Array(name.utf8)
        for table in list.split(separator: "\n").reversed() {
            // Mapped, not read: only the pages the lookup touches load (the
            // header and the first block, for HEAD), so a repository's main
            // stack of a monorepo's refs costs no more than a worktree's.
            // Tables are never rewritten in place, only replaced, so the
            // mapping can't change under us.
            let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(String(table)))
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { return nil } // compacted under us: git will know
            switch lookup(key, in: data) {
            case .notHere: continue
            case .found(let target): return target
            case .unreadable: return nil
            }
        }
        return nil
    }

    enum Lookup: Equatable {
        /// This table says nothing about the ref: an older one may.
        case notHere
        /// The newest word on it: its symbolic target, or nil for an object
        /// id or a deletion.
        case found(String?)
        case unreadable
    }

    /// The record for `key` in one table's bytes.
    nonisolated static func lookup<Bytes: RandomAccessCollection>(_ key: [UInt8], in bytes: Bytes) -> Lookup
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard bytes.startIndex == 0 else { return lookup(key, in: Array(bytes)) }
        var reader = Reader(bytes: bytes)
        // Header: "REFT", version, uint24 block size, two uint64 update
        // indexes; version 2 adds a uint32 hash id ("sha1" or "s256").
        guard bytes.count >= 24, bytes.starts(with: Array("REFT".utf8)) else { return .unreadable }
        let version = bytes[4]
        let blockSize = Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        let headerSize: Int
        var hashSize = 20
        switch version {
        case 1: headerSize = 24
        case 2:
            guard bytes.count >= 28 else { return .unreadable }
            headerSize = 28
            switch Array(bytes[24..<28]) {
            case Array("sha1".utf8): break
            case Array("s256".utf8): hashSize = 32
            default: return .unreadable
            }
        default: return .unreadable
        }

        // Ref blocks come first, `r` and a uint24 length. The first block's
        // length counts from the start of the file (the header is part of
        // it); with a block size set, each later block starts on a multiple
        // of it, and without one, where the last ended.
        var blockStart = 0
        reader.position = headerSize
        while reader.position + 4 <= bytes.count, bytes[reader.position] == UInt8(ascii: "r") {
            let p = reader.position
            let length = Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            let blockEnd = blockStart + length
            guard blockEnd <= bytes.count, blockEnd >= p + 6 else { return .unreadable }
            // The block ends in uint24 restart offsets and a uint16 count of
            // them; the records stop where those begin.
            let restarts = Int(bytes[blockEnd - 2]) << 8 | Int(bytes[blockEnd - 1])
            let recordsEnd = blockEnd - 2 - 3 * restarts
            guard recordsEnd >= p + 4 else { return .unreadable }

            reader.position = p + 4
            var previous: [UInt8] = []
            while reader.position < recordsEnd {
                guard let prefix = reader.varint(), let suffixAndType = reader.varint(),
                      prefix <= previous.count else { return .unreadable }
                let suffixLength = suffixAndType >> 3
                guard let suffix = reader.take(suffixLength),
                      reader.varint() != nil // update index delta
                else { return .unreadable }
                previous = Array(previous[..<prefix]) + suffix

                var target: String?
                switch suffixAndType & 0x7 {
                case 0: break // deletion
                case 1: guard reader.take(hashSize) != nil else { return .unreadable }
                case 2: guard reader.take(2 * hashSize) != nil else { return .unreadable }
                case 3:
                    guard let length = reader.varint(), let text = reader.take(length) else { return .unreadable }
                    target = String(decoding: text, as: UTF8.self)
                default: return .unreadable
                }
                if previous == key { return .found(target) }
                // Sorted: past where it would be, so it isn't in this table.
                if previous.lexicographicallyPrecedes(key) == false { return .notHere }
            }
            blockStart = blockSize > 0 ? (blockEnd + blockSize - 1) / blockSize * blockSize : blockEnd
            reader.position = blockStart
        }
        return .notHere
    }

    private struct Reader<Bytes: RandomAccessCollection> where Bytes.Element == UInt8, Bytes.Index == Int {
        let bytes: Bytes
        var position = 0

        mutating func take(_ count: Int) -> Bytes.SubSequence? {
            guard count >= 0, position + count <= bytes.count else { return nil }
            defer { position += count }
            return bytes[position..<position + count]
        }

        /// Git's varint (the one in pack offsets), not LEB128: each
        /// continuation adds one before shifting, so no value has two
        /// encodings.
        mutating func varint() -> Int? {
            guard position < bytes.count else { return nil }
            var byte = bytes[position]; position += 1
            var value = Int(byte & 0x7f)
            while byte & 0x80 != 0 {
                guard position < bytes.count, value < Int.max >> 8 else { return nil }
                byte = bytes[position]; position += 1
                value = ((value + 1) << 7) | Int(byte & 0x7f)
            }
            return value
        }
    }
}
