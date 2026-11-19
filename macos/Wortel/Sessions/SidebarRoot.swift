import Foundation

/// The sidebar outline's root level, by index.
///
/// The root holds, top to bottom: the Pinned header (while anything is
/// pinned), one header per folder, the Sessions header (while any session is
/// in no folder), and then the folderless sessions themselves. Those are root
/// rows, not the Sessions header's children, so folding Sessions takes them
/// out of the outline (`looseShown` is then 0) rather than collapsing an item.
///
/// Pure, and a type of its own, because the coordinator turns these indices
/// into rows, drops and the insertion line in a dozen places, and a wrong one
/// doesn't throw: it draws the wrong row, or files a dropped session in the
/// wrong section, which renames it.
struct SidebarRoot: Equatable {
    /// The Pinned header is there.
    var pinned: Bool
    /// How many folder headers.
    var folders: Int
    /// The Sessions header is there.
    var loose: Bool
    /// How many folderless rows are in the outline: 0 while Sessions is folded.
    var looseShown: Int

    enum Slot: Equatable {
        case pinnedHeader
        case folder(Int)
        case looseHeader
        case loose(Int)
    }

    /// The root's child count.
    var count: Int { firstLoose + looseShown }

    /// The root index of the first folder header.
    var firstFolder: Int { pinned ? 1 : 0 }

    /// The root index of the Sessions header, nil without one.
    var looseHeader: Int? { loose ? firstFolder + folders : nil }

    /// The root index of the first folderless row (and, as a drop index, the
    /// top of the Sessions section).
    var firstLoose: Int { firstFolder + folders + (loose ? 1 : 0) }

    /// The root indices of the folderless rows in the outline.
    var looseRows: Range<Int> { firstLoose..<(firstLoose + looseShown) }

    /// What sits at root index `index`; nil past the end.
    func slot(at index: Int) -> Slot? {
        guard index >= 0, index < count else { return nil }
        if pinned, index == 0 { return .pinnedHeader }
        if index < firstFolder + folders { return .folder(index - firstFolder) }
        if index == looseHeader { return .looseHeader }
        return .loose(index - firstLoose)
    }

    /// The root index of folder header `i`.
    func rootIndex(ofFolder i: Int) -> Int { firstFolder + i }

    /// The root index of folderless row `i`.
    func rootIndex(ofLoose i: Int) -> Int { firstLoose + i }

    /// The place in the folder order a root drop index between sections
    /// means: never above Pinned, never below the last folder.
    func folderIndex(forDrop index: Int) -> Int { min(max(0, index - firstFolder), folders) }

    /// The place among the folderless rows a root drop index means.
    func looseIndex(forDrop index: Int) -> Int { min(max(0, index - firstLoose), looseShown) }
}
