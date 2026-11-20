import Foundation
import GhosttyKit
import os

/// Where a session's channel goes while the keeper keeps its terminal
/// (`KeeperCommand.terminal`): to the surface showing it, if one does, and to
/// everything that reads the program's output for what it says about itself.
///
/// The surface comes and goes (dropped while out of sight, made again when
/// shown), the channel does not: it is read for as long as the session lives,
/// so the status dots never miss a byte. A surface that is new waits for a
/// snapshot (`KeeperChannel`), is restored from it exactly, and is then fed
/// what follows it; output that came before the snapshot is already in it.
///
/// **On the session's read queue only** (`PtyHost`), every method: the frames
/// arrive there, and a surface is swapped in or out there, between two reads.
final class KeptTerminalFeed {
    private var reader = KeeperChannelReader()
    private var surface: ghostty_surface_t?
    private var awaitingSnapshot = true
    private var waitsForSize = false
    private var restored: ((Bool) -> Void)?

    private let session: UUID
    private let status: ProgramStatusWatch
    private let accessibility: SurfaceAccessibilityWatch
    private weak var pty: PtyHost?

    init(session: UUID, status: ProgramStatusWatch, accessibility: SurfaceAccessibilityWatch, pty: PtyHost) {
        self.session = session
        self.status = status
        self.accessibility = accessibility
        self.pty = pty
    }

    /// Show the session in `surface`, from the next snapshot on. `waitsForSize`:
    /// the view is about to tell it its size, so the snapshot waits for that
    /// rather than being re-wrapped from libghostty's placeholder grid on the
    /// way. `restored` is called on this queue once it is, with whether the
    /// snapshot decoded.
    func show(in surface: ghostty_surface_t, waitsForSize: Bool, restored: ((Bool) -> Void)? = nil) {
        self.surface = surface
        self.awaitingSnapshot = true
        self.waitsForSize = waitsForSize
        self.restored = restored
    }

    /// Stop writing into the surface; it is about to be freed.
    func hide() {
        surface = nil
        awaitingSnapshot = true
        restored = nil
    }

    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        reader.feed(bytes, count: count) { piece in
            switch piece {
            case .snapshot(let snapshot):
                // One nobody is waiting for (a request crossed a drop) is a
                // point already shown; what follows it still is.
                guard let surface, awaitingSnapshot else { return }
                if waitsForSize, !SurfaceView.waitForToldGrid(surface).reached {
                    KeeperLog.log.notice("session \(self.session.uuidString, privacy: .public) restored before its terminal took its size")
                }
                let ok = snapshot.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                    return ghostty_surface_restore_snapshot(surface, base, UInt(raw.count))
                }
                if !ok {
                    KeeperLog.log.error("""
                        session \(self.session.uuidString, privacy: .public): a snapshot of \
                        \(snapshot.count) bytes would not restore
                        """)
                }
                awaitingSnapshot = false
                waitsForSize = false
                let restored = self.restored
                self.restored = nil
                restored?(ok)
            case .output(let output):
                guard let base = output.baseAddress else { return }
                // The record of the program's modes, which agent sleep and
                // the light/dark handling read (`TerminalModes`).
                TerminalModeRecorder.shared.feed(session: session, bytes: base, count: output.count)
                status.output(base, count: output.count, pty: pty)
                guard let surface, !awaitingSnapshot else { return }
                ghostty_surface_write_buffer_replay(surface, base, UInt(output.count))
                accessibility.outputArrived()
            case .invalid:
                KeeperLog.log.error("session \(self.session.uuidString, privacy: .public): its channel is not a keeper's")
            }
        }
    }
}
