import AppKit
import Foundation
import Observation

/// What every session is running right now, kept roughly current.
///
/// The scan itself is cheap (605 processes shaped in 1.0 ms on a real machine),
/// but it is a pile of `sysctl` and `libproc` calls and there is no reason for
/// any of it to happen on the main thread, so it doesn't. The cadence is slow
/// and coalescable because nothing here is urgent: a dev server that started
/// ten seconds ago is not news.
@Observable
@MainActor
final class ProcessMonitor {
    /// The most recent scan. Empty until the first one lands.
    private(set) var snapshot: RunningJobsSnapshot = .empty

    /// Where the sessions are, supplied by `SessionManager` because this type
    /// deliberately knows nothing about sessions beyond their shell pids.
    @ObservationIgnored var roots: () -> [SessionProcessRoot] = { [] }

    /// Directories an orphan has to be sitting in to count as ours.
    @ObservationIgnored var projectRoots: () -> [String] = { [] }

    /// How often to re-scan while the window is up. Slow on purpose: this is
    /// ambient information, and a tighter loop would buy nothing but wakeups.
    static let sampleInterval: TimeInterval = 10

    /// How long a job gets to honour SIGTERM before it is killed outright.
    static let killGrace: TimeInterval = 3

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var scanning = false

    // MARK: - Cadence

    func startSampling() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A background poll has no deadline; the tolerance lets the OS coalesce
        // it with other timers rather than waking the CPU on its own.
        timer.tolerance = Self.sampleInterval / 4
        self.timer = timer
        refresh()
    }

    func stopSampling() {
        timer?.invalidate()
        timer = nil
        endActivity()
    }

    /// Scan now, off the main thread, and publish when it lands.
    ///
    /// Re-entrant calls are dropped rather than queued: the answer a scan
    /// already in flight is about to produce is the same answer.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let request = ScanRequest(roots: roots(), projectRoots: projectRoots())
        Task.detached(priority: .utility) {
            let result = request.run()
            await MainActor.run { [weak self] in
                self?.snapshot = result
                self?.scanning = false
            }
        }
    }

    /// Scan synchronously, for the one caller that cannot wait: the sheet that
    /// has to name what closing a session will stop. It is milliseconds, and
    /// the alternative is a dialog that appears and then changes its mind.
    func scanNow() -> RunningJobsSnapshot {
        let result = ScanRequest(roots: roots(), projectRoots: projectRoots()).run()
        snapshot = result
        return result
    }

    // MARK: - Quitting a job

    /// Ask a job to stop, then insist.
    ///
    /// SIGTERM rather than the SIGHUP `PtyHost` uses, because this is a program
    /// being asked to shut down rather than a shell losing its terminal, and a
    /// dev server that traps SIGTERM to clean up should get to.
    ///
    /// The escalation deliberately does **not** re-signal `-pgid`. By the time
    /// the grace window is up that group number may belong to something else
    /// entirely, and `kill(-pgid, SIGKILL)` would take it out. Instead it kills
    /// the individual processes it originally asked to stop, and only those that
    /// are still in the same group — a recycled pid would have to land back in
    /// the same group to be hit, which does not happen.
    func quit(_ job: RunningJob) {
        guard job.isKillable, job.pgid > 1 else { return }

        if kill(-job.pgid, SIGTERM) != 0 {
            // No process group (already gone, or never one): fall back to the
            // members directly rather than giving up.
            for pid in job.pids where pid > 1 { kill(pid, SIGTERM) }
        }

        let pids = Set(job.pids.filter { $0 > 1 })
        let pgid = job.pgid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) {
            let survivors = ProcessTable.snapshot()
                .filter { pids.contains($0.pid) && $0.pgid == pgid }
            for survivor in survivors { kill(survivor.pid, SIGKILL) }
            Task { @MainActor [weak self] in self?.refresh() }
        }

        // Take the row away now. The next scan confirms it, but a Quit button
        // that leaves its row sitting there reads as a button that did nothing.
        snapshot = RunningJobsSnapshot(
            jobs: snapshot.jobs.filter { $0.pgid != job.pgid },
            orphans: snapshot.orphans.filter { $0.pgid != job.pgid })
    }

    // MARK: - App Nap

    /// Hold off App Nap only while something is actually worth watching, and say
    /// why — the reason string is what shows up in Activity Monitor's
    /// "Preventing Sleep" column.
    func updateActivityAssertion() {
        let wanted = !snapshot.isEmpty && timer != nil
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Tracking servers left running in terminal sessions")
        } else if !wanted {
            endActivity()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// One scan's inputs, captured on the main actor so the work itself can run
/// anywhere. A struct rather than a closure so nothing about `ProcessMonitor`
/// has to be `Sendable`.
private struct ScanRequest: Sendable {
    let roots: [SessionProcessRoot]
    let projectRoots: [String]

    func run() -> RunningJobsSnapshot {
        RunningJobs.scan(
            table: ProcessTable.snapshot(),
            roots: roots,
            projectRoots: projectRoots,
            // Wortel and its keeper must never appear in their own list.
            excludedPGIDs: [getpgrp()])
    }
}

extension SessionProcessRoot: @unchecked Sendable {}
