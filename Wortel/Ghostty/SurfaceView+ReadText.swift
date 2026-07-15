import AppKit
import GhosttyKit

extension SurfaceView {
    /// The terminal's current on-screen text (the visible viewport), rebuilt
    /// from libghostty's cell grid. Wortel doesn't own the character buffer —
    /// the Zig core does — so "reading the screen" means handing it a region
    /// (here: top-left to bottom-right of the viewport) and getting the joined
    /// text back. Mirrors the `read_selection` dance used by NSTextInputClient,
    /// but with a region we specify instead of the user's highlight.
    ///
    /// Returns the rendered screen *as drawn* — for a full-screen TUI (an agent
    /// like Claude Code) that includes its box-drawing chrome and only the
    /// current screenful. `SessionNameGenerator.distill` trims that down before
    /// it reaches the model. Nil when there's no surface or the read fails.
    func readScreenText() -> String? {
        guard let surface else { return nil }
        func corner(_ coord: ghostty_point_coord_e) -> ghostty_point_s {
            ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: coord, x: 0, y: 0)
        }
        let region = ghostty_selection_s(
            top_left: corner(GHOSTTY_POINT_COORD_TOP_LEFT),
            bottom_right: corner(GHOSTTY_POINT_COORD_BOTTOM_RIGHT),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, region, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text != nil else { return nil }
        return String(cString: text.text)
    }
}
