import Foundation

/// Where you were: a session and the tab you last brought forward in it.
/// Back and Forward step through these, so Files, then Changes, then a file,
/// then another session is a trail you can walk back the way you came, inside
/// one session and across them alike.
struct WorkspacePlace: Hashable, Sendable {
    let session: UUID
    let tab: SideTab
}

/// Back and Forward through the places you've been (a session and the tab
/// you had in front in it), as a browser keeps pages: `back` is the trail you
/// took, oldest first, and `forward` is what Back has stepped away from,
/// nearest last. Going somewhere yourself is a visit (what you left goes on
/// Back, Forward is gone, as following a link after going back is in a
/// browser); Back and Forward are steps, which trade the current place for
/// the nearest open one on the other side.
///
/// Sessions and tabs close under it, so every question is asked with
/// `isOpen`, and an entry that is closed, or is the place you are already on,
/// is never one to step to. The titlebar's arrows and the Go menu ask
/// `canStep`, which must agree exactly with whether `step` would move.
///
/// A type of its own, pure over ids, because every way it is wrong is silent:
/// an arrow that looks live and does nothing when pressed, or a step that
/// lands on a session that was just closed.
struct SessionHistory<ID: Hashable>: Equatable {
    enum Direction { case back, forward }

    private(set) var back: [ID] = []
    private(set) var forward: [ID] = []
    /// A trail through one run, not a log: the oldest entries go first.
    static var limit: Int { 100 }

    /// You selected something yourself: what you left goes on Back, and
    /// Forward is gone. `previous` is what you left, if it is still open.
    mutating func visit(from previous: ID?, isOpen: (ID) -> Bool) {
        guard let previous, isOpen(previous) else { return }
        if back.last != previous { back.append(previous) }
        if back.count > Self.limit {
            back.removeFirst(back.count - Self.limit)
        }
        if !forward.isEmpty { forward.removeAll() }
    }

    /// The nearest entry in `direction` that is open and isn't `current`.
    /// Entries stepped over are dropped; `current` goes on the other side.
    /// nil, with the dead entries still dropped, when there is nowhere to go.
    mutating func step(_ direction: Direction, from current: ID?, isOpen: (ID) -> Bool) -> ID? {
        var source = direction == .back ? back : forward
        var other = direction == .back ? forward : back
        defer {
            back = direction == .back ? source : other
            forward = direction == .back ? other : source
        }
        while let id = source.popLast() {
            guard isOpen(id), id != current else { continue }
            if let current { other.append(current) }
            return id
        }
        return nil
    }

    /// Whether `step` would move.
    func canStep(_ direction: Direction, from current: ID?, isOpen: (ID) -> Bool) -> Bool {
        let list = direction == .back ? back : forward
        return list.contains { $0 != current && isOpen($0) }
    }

    /// A session closed: it is in neither list any more.
    mutating func forget(_ id: ID) {
        forget(where: { $0 == id })
    }

    /// Drop every entry `matches` says to: a closed session's places. What
    /// is left keeps its order.
    mutating func forget(where matches: (ID) -> Bool) {
        back.removeAll(where: matches)
        forward.removeAll(where: matches)
    }
}
