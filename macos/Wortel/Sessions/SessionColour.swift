import Foundation

/// A colour you give a session by hand, shown as a bar at the leading edge of
/// its sidebar row: "come back to this" for a session that's nearly done but
/// worth keeping alive (a PR waiting on CI), told apart by colour.
///
/// Finder's tag colours, in Finder's order, so the set needs no learning. It
/// says nothing to the app: no colour changes what a session does, and none is
/// ever set or cleared except by you (the menu, or `wortel mark`).
///
/// Pure (Foundation only) so the file format and the CLI's validation can be
/// tested without the app; the colours themselves are mapped in the UI layer,
/// as `AttentionKind`'s are.
enum SessionColour: String, CaseIterable, Codable {
    case red, orange, yellow, green, blue, purple, grey

    /// Its name in a menu.
    var title: String { rawValue.capitalized }

    /// What `wortel mark` takes besides a colour: clear it.
    static let none = "none"

    /// A colour as typed on the command line, or nil for one Wortel doesn't
    /// have. Case is forgiven, and so is the other spelling of grey.
    static func named(_ name: String) -> SessionColour? {
        let name = name.lowercased()
        return SessionColour(rawValue: name == "gray" ? "grey" : name)
    }
}
