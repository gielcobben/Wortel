import Foundation
import GhosttyKit

/// Reading what a surface is currently *drawing*: the end of its active
/// screen, as text, for a tab's preview. Deliberately narrow. It used to be
/// hashed once a second per agent to guess whether the agent was working;
/// nothing is guessed from a screen any more (`docs/agent-signals.md`).
extension SurfaceView {
    /// The selection covering the active screen — the program's live output,
    /// not the scrollback. Using the active area rather than the viewport means
    /// scrolling back through history is not mistaken for the agent doing
    /// something, and reading it does not disturb the user's scroll position.
    private static var activeScreen: ghostty_selection_s {
        ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
    }

    /// The last `maxBytes` of the active screen as text. Only called at the
    /// moment a screen goes quiet, which is the one time the content itself
    /// matters — a prompt's affordances live at the bottom, hence the tail.
    func activeScreenTail(maxBytes: Int = 2048) -> String? {
        withActiveScreen { bytes in
            guard !bytes.isEmpty else { return nil }
            var start = bytes.count > maxBytes ? bytes.count - maxBytes : 0
            // Don't start mid-character: step over UTF-8 continuation bytes so
            // the tail can't open with a replacement character.
            while start < bytes.count, start > 0, bytes[start] & 0xC0 == 0x80 {
                start += 1
            }
            return String(decoding: bytes[start...], as: UTF8.self)
        }
    }

    /// Shared read/free pair. The buffer belongs to libghostty and is only
    /// valid inside `body`, so nothing may escape it but the derived value.
    private func withActiveScreen<T>(_ body: (UnsafeRawBufferPointer) -> T?) -> T? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, Self.activeScreen, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return body(UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)))
    }
}
