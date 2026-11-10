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

    /// Bumped by anything that makes an in-flight background scan stale: a
    /// synchronous scan, or a job being stopped. A background scan that lands
    /// after one of those carries an older picture, and publishing it would
    /// put a stopped row back, or drop an ownership record the newer scan made.
    @ObservationIgnored private var generation = 0

    /// Who started what, carried from scan to scan and across launches. See
    /// `RunningJobs.recordingOwners` and `ProcessOwnersStore`.
    @ObservationIgnored private var owners: ProcessOwners = ProcessOwnersStore.load()

    /// Each process's session tag, read once. See `SessionTagCache`.
    @ObservationIgnored private let sessionTags = SessionTagCache()

    /// Take a scan's ownership map, writing it down only when it changed: a
    /// scan every ten seconds that finds the same servers writes nothing.
    private func adopt(_ updated: ProcessOwners) {
        guard updated != owners else { return }
        owners = updated
        ProcessOwnersStore.save(updated)
    }

    // MARK: - Cadence

    func startSampling() {
        guard timer == nil else { return }
        schedule(every: Self.sampleInterval)
        refresh()
    }

    /// While Wortel is behind other apps nobody is reading the list, so it's
    /// kept a third as fresh; coming back scans at once. (Closing a session
    /// scans for itself, `scanNow`, so it never acts on an old answer.)
    func setInBackground(_ background: Bool) {
        guard timer != nil else { return }
        schedule(every: background ? Self.sampleInterval * 3 : Self.sampleInterval)
        if !background { refresh() }
    }

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A background poll has no deadline; the tolerance lets the OS coalesce
        // it with other timers rather than waking the CPU on its own.
        timer.tolerance = interval / 4
        self.timer = timer
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
        let request = ScanRequest(roots: roots(), projectRoots: projectRoots(),
                                  owners: owners, sessionTags: sessionTags)
        let started = generation
        Task.detached(priority: .utility) {
            let result = request.run()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.generation == started else { return }
                self.adopt(result.owners)
                self.snapshot = result.snapshot
            }
        }
    }

    /// Scan synchronously, for the one caller that cannot wait: the sheet that
    /// has to name what closing a session will stop. It is milliseconds, and
    /// the alternative is a dialog that appears and then changes its mind.
    func scanNow() -> RunningJobsSnapshot {
        generation += 1
        let result = ScanRequest(roots: roots(), projectRoots: projectRoots(),
                                 owners: owners, sessionTags: sessionTags).run()
        adopt(result.owners)
        snapshot = result.snapshot
        scannedAt = Date()
        return result.snapshot
    }

    /// When `scanNow` last ran, for `recentScan`.
    private var scannedAt: Date?

    /// `scanNow`, unless one ran within the last second: then that one.
    ///
    /// One close asks three questions in a row (is anything running, what to
    /// name in the sheet, what to stop) and a batch asks the first of them
    /// once a session; each used to scan the whole process table on the main
    /// thread. A second is far inside the ten the background sample can be
    /// stale by, which is the staleness these callers exist to avoid, and a
    /// sheet left open longer than that scans again when it is answered.
    func recentScan() -> RunningJobsSnapshot {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < 1 { return snapshot }
        return scanNow()
    }

    /// Stop everything a session started, because the session is closing.
    ///
    /// Closing only hangs up the shell, and a hang-up is advisory: `nohup`,
    /// `disown`, and every dev server that daemonises itself shrug it off and
    /// are reparented to launchd, still holding `:3000` with nothing on screen
    /// to say so. The close sheet already promised "Closing stops …"; this is
    /// what makes that true.
    ///
    /// Scanned within the last second rather than read from the background
    /// snapshot, which can be ten seconds old and so miss the server started
    /// just before ⌘W.
    func stopWork(of sessionID: UUID) {
        let doomed = recentScan().workToStop(for: sessionID)
        for job in doomed { terminate(job) }
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
        Telemetry.capture(.processQuit(orphan: job.sessionID == nil))
        terminate(job)
    }

    /// The signalling half of `quit`, without counting it as somebody choosing
    /// to quit from the list: a session closing is not that.
    private func terminate(_ job: RunningJob) {
        guard job.isKillable, job.pgid > 1 else { return }
        generation += 1

        // Only signal the group when this job *is* the group. One command can
        // start several servers into one group (`bun dev` fanning out to
        // `dev:web` and `dev:images`), and there `kill(-pgid, …)` would stop
        // both from a row that names one.
        if job.ownsGroup, kill(-job.pgid, SIGTERM) == 0 {
            // Signalled the whole group; its members are the same processes.
        } else {
            for pid in job.pids where pid > 1 { kill(pid, SIGTERM) }
        }

        let pids = Set(job.pids.filter { $0 > 1 })
        let pgid = job.pgid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) {
            let survivors = ProcessTable.snapshot()
                .filter { pids.contains($0.pid) && $0.pgid == pgid }
            // The escalation is per-process either way, so a shared group is
            // safe here for the same reason the SIGTERM above is.
            for survivor in survivors { kill(survivor.pid, SIGKILL) }
            Task { @MainActor [weak self] in self?.refresh() }
        }

        // Take the row away now. The next scan confirms it, but a Quit button
        // that leaves its row sitting there reads as a button that did nothing.
        // By id, not `pgid`: two jobs can share a group, and filtering on the
        // group would take the sibling's row away too, for a server still
        // running.
        snapshot = RunningJobsSnapshot(
            jobs: snapshot.jobs.filter { $0.id != job.id },
            orphans: snapshot.orphans.filter { $0.id != job.id })
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
    let owners: ProcessOwners
    let sessionTags: SessionTagCache

    func run() -> (snapshot: RunningJobsSnapshot, owners: ProcessOwners) {
        let table = ProcessTable.snapshot()
        // An unreadable table claims nothing, and must not forget anything
        // either: pruning against an empty table would drop every record.
        guard !table.isEmpty else { return (.empty, owners) }
        var details = ProcessDetails.live
        details.sessionTag = sessionTags.lookup
        defer { sessionTags.prune(keeping: table) }
        let snapshot = RunningJobs.scan(
            table: table,
            roots: roots,
            projectRoots: projectRoots,
            // Wortel and its keeper must never appear in their own list.
            excludedPGIDs: [getpgrp()],
            owners: owners,
            details: details)
        return (snapshot, RunningJobs.recordingOwners(snapshot, table: table,
                                                       previous: owners))
    }
}


/// Which session each process was started in, read from its environment once
/// per process lifetime.
///
/// The detached-server pass asks this of every group no session's tree holds,
/// which is most of the machine: a few hundred login agents and app helpers.
/// The answer cannot change (it is the environment at `exec`), so it is kept
/// by `ProcessKey` and the steady state costs nothing. A recycled pid has a
/// different start time and is read afresh. Locked because the scan runs off
/// the main actor and `scanNow` runs on it.
final class SessionTagCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [ProcessKey: UUID?] = [:]

    func lookup(_ entry: ProcessEntry) -> UUID? {
        let key = ProcessKey(entry)
        lock.lock()
        if let cached = tags[key] { lock.unlock(); return cached }
        lock.unlock()
        let tag = ProcessTable.sessionTag(of: entry.pid)
        lock.lock()
        tags[key] = .some(tag)
        lock.unlock()
        return tag
    }

    /// Forget processes that have exited, so the cache is never bigger than
    /// the table.
    func prune(keeping table: [ProcessEntry]) {
        let live = Set(table.map { ProcessKey($0) })
        lock.lock()
        tags = tags.filter { live.contains($0.key) }
        lock.unlock()
    }
}
