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
        defer { ghosttyFreeText(&text) }
        guard text.text != nil else { return nil }
        return String(cString: text.text)
    }

    /// The terminal's text for `wortel read`: the active screen, or with
    /// `includingScrollback` everything from the top of the scrollback down.
    ///
    /// The *active* screen rather than the viewport: the active area is what
    /// the program last drew, the viewport is wherever the person at the
    /// keyboard has scrolled to, and an agent asking what another session
    /// says wants the first. For a session nobody is scrolling the two are
    /// the same rows. Raw: `ScreenText.tidy` trims it for the caller.
    func readText(includingScrollback: Bool) -> String? {
        guard let surface else { return nil }
        let tag = includingScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_ACTIVE
        let region = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, region, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
                      as: UTF8.self)
    }

    /// How much output has reached this terminal, as a number that only
    /// moves (`PtyHost.outputGeneration`); nil on the exec backend, which
    /// doesn't say. Lets a waiter skip reading a screen nothing has written to.
    var outputGeneration: UInt64? { ptyHost?.outputGeneration }

    /// Run `body` on the main thread once everything already handed to this
    /// terminal has reached its screen: on the pty's queue (`PtyHost.enqueue`),
    /// behind what is being written into it, and after a woken surface has
    /// been restored from the keeper's terminal (`afterRestore`). Until then
    /// a woken surface is blank, and `wortel read` read it as that: the first
    /// read of a dropped terminal came back empty and the second did not
    /// (2026-11-20). On the exec backend, which has no such queue, at once.
    func afterPendingOutput(_ body: @escaping @MainActor () -> Void) {
        guard let pty = ptyHost else { return body() }
        pty.enqueue {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.afterRestore { body() } } }
        }
    }

    /// Run `body(true)` once a paste would reach the program as it should:
    /// after the pending output, which includes a woken surface being restored
    /// from the keeper's terminal (`wake`). Before that, the surface does not
    /// yet know the program asked for bracketed paste, so a multi-line prompt
    /// would land as one submission per line.
    ///
    /// Or `body(false)` once `patience` has run out, and then never
    /// `body(true)`: the caller (`wortel send`) has a deadline of its own to
    /// answer within, and typing after it has given up is how a retried
    /// prompt gets sent twice. Called exactly once.
    func whenPasteReachesProgram(within patience: TimeInterval,
                                 _ body: @escaping @MainActor (_ ready: Bool) -> Void) {
        let once = Once(body)
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) {
            MainActor.assumeIsolated { once.call(false) }
        }
        // And after a start still under its cover (`StartCover`), for the
        // same reason: the program is not there yet to have asked. Whatever
        // came of the start, `wortel send` was told to type, and does. A
        // start is over inside `patience` (`StartCover.Patience.shell`).
        afterStart { [weak self] _ in
            guard let self else { return }
            self.afterPendingOutput { once.call(true) }
        }
    }

    /// The first answer of the two that race, the deadline's or the ready one.
    @MainActor
    private final class Once {
        private var body: (@MainActor (Bool) -> Void)?
        init(_ body: @escaping @MainActor (Bool) -> Void) { self.body = body }
        func call(_ ready: Bool) {
            let body = self.body
            self.body = nil
            body?(ready)
        }
    }
}

/// Give back text libghostty handed out (`ghostty_surface_read_text`,
/// `ghostty_surface_read_selection`). Every read goes through this.
///
/// **Not `ghosttyFreeText(&text)`**, though that is what
/// ghostty.h declared. In the libghostty this app linked until 2026.47.4
/// (Ghostty 1.2) the function took one argument, the text, and read the
/// first one as it:
/// handed the surface, it read the surface's own memory as the text and
/// freed nothing. Every read leaked its text, and the agent screen tier (gone
/// since) read every agent session's screen once a second: 564 MB of screens after four
/// and a half hours with 13 sessions (measured 2026-11-17, `heap` and
/// `malloc_history`). It also meant freeing whatever pointer the surface
/// happened to hold at that offset. Ghostty fixed the declaration upstream
/// (4803d58, the surface became a first, ignored argument), and the Ghostty
/// linked since 2026.47.4 has that fix. The text still goes in both places,
/// which is right for either.
func ghosttyFreeText(_ text: inout ghostty_text_s) {
    withUnsafeMutablePointer(to: &text) { pointer in
        ghostty_surface_free_text(UnsafeMutableRawPointer(pointer), pointer)
    }
}
