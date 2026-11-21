import Foundation

/// The "Folder/Leaf" convention the sidebar is grouped by, as pure string
/// handling. A session's folder is not a field — it's encoded in the name, and
/// renaming is the only way to move between folders — so this split is the whole
/// of that feature, and it's read from three places (grouping, the row label,
/// and the rename field's selection). One copy, no AppKit, so `SessionNameTests`
/// can pin it without standing up the app shell.
///
/// Everything splits on the **last** slash: a name is always one folder plus one
/// leaf, so "a/b/c" is folder "a/b" leaf "c" rather than a nested tree.
enum SessionName {
    /// The folder a name lives in, or nil for a top-level session.
    static func folder(of name: String) -> String? {
        guard let slash = name.range(of: "/", options: .backwards) else { return nil }
        let prefix = name[..<slash.lowerBound].trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? nil : prefix
    }

    /// The name with any folder prefix stripped — what a sidebar row shows.
    /// A name that is all prefix ("Acme/") has no leaf to show, so it falls
    /// back to the whole name rather than rendering an empty row.
    static func leaf(of name: String) -> String {
        guard let slash = name.range(of: "/", options: .backwards) else { return name }
        let leaf = name[slash.upperBound...].trimmingCharacters(in: .whitespaces)
        return leaf.isEmpty ? name : leaf
    }

    /// A generated name, made safe to store as a leaf. Automatic names come
    /// from an agent's title, the on-device model, or the user's first prompt,
    /// and all three are full of paths: "Debug web/src build" stored as-is
    /// would be read back by `folder(of:)` as a session called "src build" in
    /// a folder called "Debug web". The slash becomes the division slash
    /// (U+2215), which reads the same but is not the folder separator, so a
    /// path in a name stays legible as a path. Only automatic names go
    /// through this: a slash the user types is how a session is moved.
    static func asLeaf(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "/", with: "\u{2215}")
        return flat.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Where `leaf(of:)` sits inside the full name, for selecting it in the
    /// rename field. UTF-16 because that's what AppKit's text system counts in —
    /// a folder named with an emoji would otherwise offset the selection.
    ///
    /// nil means "no leaf worth selecting on its own" — either a top-level name
    /// (no slash) or one that's all prefix — and the caller should leave the
    /// field's default whole-string selection alone.
    static func leafRange(of name: String) -> NSRange? {
        guard let slash = name.range(of: "/", options: .backwards) else { return nil }
        var start = slash.upperBound
        var end = name.endIndex
        // Match `leaf(of:)`'s trimming, so the selection covers the text the row
        // actually showed and not the spaces around it.
        while start < end, name[start].isWhitespace { start = name.index(after: start) }
        while end > start, name[name.index(before: end)].isWhitespace { end = name.index(before: end) }
        guard start < end else { return nil }
        return NSRange(start..<end, in: name)
    }
}
