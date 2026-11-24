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
    /// A snapshot that came with no surface to show it in, kept until output
    /// makes it stale: the one the keeper sends as a session ends, which is
    /// all there is to show of a session whose surface was dropped by then.
    private var held: Data?
    /// While there is no surface: reads what the surface would have raised
    /// (titles, the working directory, bells, progress, a command ending).
    /// Fresh each time the surface goes; with a surface, libghostty does it.
    private var scanner: SignalScanner?
    /// Where the scanner's signals go, on the main thread (`SurfaceView.raise`).
    var onSignals: (([SignalScanner.Signal]) -> Void)?

    /// While the session starts (`StartCover`): reads the output for the
    /// shell running its first line and the program's interface coming up.
    /// nil the rest of the session's life, which is nearly all of it.
    private var startScanner: StartScanner?
    private var onStartEvents: (([StartCover.Event], TimeInterval) -> Void)?

    private let session: UUID
    private let status: ProgramStatusWatch
    private let accessibility: SurfaceAccessibilityWatch

    init(session: UUID, status: ProgramStatusWatch, accessibility: SurfaceAccessibilityWatch) {
        self.session = session
        self.status = status
        self.accessibility = accessibility
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
        if let held {
            self.held = nil
            apply(held)
        }
    }

    /// Read the output for how the session's start goes, from the next read
    /// on. `heard` is called on this queue with the events of one read and
    /// when it was read (seconds of system uptime).
    func watchStart(_ heard: @escaping ([StartCover.Event], TimeInterval) -> Void) {
        startScanner = StartScanner()
        onStartEvents = heard
    }

    /// The start is over: nothing more is read for it.
    func stopWatchingStart() {
        startScanner = nil
        onStartEvents = nil
    }

    /// The surface has taken over from the scanner: from its snapshot on, what
    /// the program says reaches the app through it.
    private func surfaceTookOver() {
        scanner = nil
    }

    /// Stop writing into the surface; it is about to be freed.
    func hide() {
        surface = nil
        awaitingSnapshot = true
        restored = nil
        scanner = SignalScanner()
    }

    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        reader.feed(bytes, count: count) { piece in
            switch piece {
            case .snapshot(let snapshot):
                // With no surface, kept for one that comes (see `held`). With
                // a surface already restored, a point already shown.
                guard surface != nil else {
                    held = snapshot
                    return
                }
                guard awaitingSnapshot else { return }
                apply(snapshot)
            case .output(let output):
                guard let base = output.baseAddress else { return }
                held = nil
                // The record of the program's modes, which agent sleep and
                // the light/dark handling read (`TerminalModes`).
                TerminalModeRecorder.shared.feed(session: session, bytes: base, count: output.count)
                status.output(base, count: output.count)
                if startScanner != nil {
                    let events = startScanner!.scan(output)
                    onStartEvents?(events, ProcessInfo.processInfo.systemUptime)
                }
                if scanner != nil {
                    var passed: [UInt8] = []
                    let signals = scanner!.scan(output, now: DispatchTime.now().uptimeNanoseconds, output: &passed)
                    if !signals.isEmpty, let onSignals {
                        DispatchQueue.main.async { onSignals(signals) }
                    }
                }
                guard let surface, !awaitingSnapshot else { return }
                ghostty_surface_write_buffer_replay(surface, base, UInt(output.count))
                accessibility.outputArrived()
            case .invalid:
                KeeperLog.log.error("session \(self.session.uuidString, privacy: .public): its channel is not a keeper's")
            }
        }
    }

    /// Restore the surface from `snapshot`, and go live after it.
    private func apply(_ snapshot: Data) {
        guard let surface else { return }
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
        surfaceTookOver()
        let restored = self.restored
        self.restored = nil
        restored?(ok)
    }
}
