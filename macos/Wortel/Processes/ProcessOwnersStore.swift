import Foundation

/// Which session started which process, remembered across launches.
///
/// The keeper keeps every session's shell alive when the app quits, so a
/// server still under its shell is re-attributed by ancestry on the first scan
/// after a relaunch and needs nothing written down. A server that has already
/// left its shell (`nohup`, `disown`, a dev server that daemonises) has nothing
/// left pointing back at its session except this record. Held only in memory,
/// every quit turned those servers into strangers: gone from their session's
/// list, and left running when that session closed.
///
/// Stale entries cost nothing. Each one is keyed by pid *and* start time, so a
/// recycled pid can never match, and the first scan drops every entry whose
/// process is gone (`RunningJobs.recordingOwners`).
enum ProcessOwnersStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wortel/process-owners.json")
    }

    /// One record. The start time is stored as `Date`'s own representation,
    /// seconds since the reference date, which JSON carries exactly. Seconds
    /// since 1970 would not: converting there and back again adds and removes
    /// an offset in floating point, and a start time that came back a bit off
    /// would match nothing, silently.
    private struct Record: Codable {
        let pid: Int32
        let startedAt: Double
        let session: UUID
    }

    static func encode(_ owners: ProcessOwners) -> Data? {
        let records = owners
            .map { Record(pid: $0.key.pid, startedAt: $0.key.startedAt.timeIntervalSinceReferenceDate,
                          session: $0.value) }
            .sorted { ($0.pid, $0.startedAt) < ($1.pid, $1.startedAt) }
        return try? JSONEncoder().encode(records)
    }

    static func decode(_ data: Data) -> ProcessOwners {
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        var owners: ProcessOwners = [:]
        for record in records {
            let key = ProcessKey(pid: record.pid,
                                 startedAt: Date(timeIntervalSinceReferenceDate: record.startedAt))
            owners[key] = record.session
        }
        return owners
    }

    static func load() -> ProcessOwners {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return decode(data)
    }

    /// Best-effort: a failure here costs a detached server its session after a
    /// relaunch, never a session.
    static func save(_ owners: ProcessOwners) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = encode(owners) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
