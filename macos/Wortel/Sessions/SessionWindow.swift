import AppKit
import Observation

/// One main window's share of the session list: which session it has in
/// front, and the little view state that can't be shared between two
/// sidebars. Every session belongs to exactly one window (`Session.windowID`);
/// a window's sidebar lists only its own.
///
/// The manager stays the one store. What it calls `selectedID` is the active
/// window's (the last main window to be key), so the commands that act on
/// "the session you're in" keep meaning that; what a window draws is read
/// from here, so the window behind shows its own session and not yours.
@Observable
@MainActor
final class SessionWindow {
    /// Stable across launches (`windows.json`). A var only so that `restore`
    /// can give the first window, made before anything was read, its saved id.
    var id: UUID

    /// The session in front in this window. Written only by the manager
    /// (`SessionManager.select(_:in:)`), which runs everything a switch means;
    /// assign `SessionManager.selectedID`, never this.
    var selectedID: Session.ID?

    /// The most recent "switched into a waiting session" here; the detail
    /// view flashes an orienting ring on each fresh value.
    var attentionFlash: AttentionFlash?

    /// ⌘1…⌘9's sessions in this window, as its sidebar draws them.
    var shortcutIDs: [Session.ID]?

    /// This window's rows top to bottom as drawn, folded sections left out.
    /// Written by its outline after each change; never read for drawing.
    @ObservationIgnored var sidebarRowOrder: [Session.ID] = []

    /// On screen: not miniaturized, not fully covered. Set from occlusion.
    @ObservationIgnored var isVisible = true

    /// Where the window was, for the next launch: `NSWindow.frameDescriptor`.
    /// Kept current by the window. The sidebar's width is not per window:
    /// it is the split's autosave, shared, as it always was.
    @ObservationIgnored var frame: String?
    /// Where a window made by a drag should put its top-left corner, in
    /// screen coordinates: where the sessions were let go.
    @ObservationIgnored var requestedTopLeft: CGPoint?

    /// Run at the end of every change of this window's session, in the same
    /// turn (`MainSplitViewController.show`).
    @ObservationIgnored var onSwitch: ((Session) -> Void)?
    /// Give the keyboard back to this window's session.
    @ObservationIgnored var onReturnKeyboard: (() -> Void)?

    @ObservationIgnored weak var manager: SessionManager?

    init(id: UUID = UUID(), manager: SessionManager?) {
        self.id = id
        self.manager = manager
    }

    var selected: Session? {
        guard let selectedID else { return nil }
        return manager?.sessions.first { $0.id == selectedID }
    }

    /// The sessions this window holds, in stored order.
    var sessions: [Session] {
        manager?.sessions(in: self) ?? []
    }
}

extension SessionManager {
    /// Set a window's front session without anything a switch means. Only
    /// for the manager's own bookkeeping (a window emptied, restore).
    func setFront(_ id: Session.ID?, of window: SessionWindow) {
        if window.selectedID != id { window.selectedID = id }
    }
}
