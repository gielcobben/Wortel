import SwiftUI

/// What every session is still running, grouped by session, with a way to stop
/// any of it.
///
/// Shaped like the battery menu's "Using Significant Energy" rather than like
/// Activity Monitor: this is a short answer to "what is holding my machine", not
/// a process browser. One row per job, the port that means something, what it
/// costs, and a Quit that appears when you point at it.
struct RunningJobsList: View {
    let monitor: ProcessMonitor
    /// Sessions are named in `SessionManager`; this view only needs to print
    /// them, so it takes a lookup rather than the whole manager.
    let sessionName: (UUID) -> String?
    let dismiss: () -> Void

    /// Wide enough for `wrangler dev --env=dev --local` plus a port and a size.
    /// `NSPopover` sizes to what the hosting controller is handed, so this frame
    /// is what gives it one at all.
    static let width: CGFloat = 340

    private var sessionSections: [(id: UUID, name: String, jobs: [RunningJob])] {
        var seen: Set<UUID> = []
        var sections: [(id: UUID, name: String, jobs: [RunningJob])] = []
        for job in monitor.snapshot.jobs {
            guard let id = job.sessionID, seen.insert(id).inserted else { continue }
            sections.append((id, sessionName(id) ?? "Session",
                             monitor.snapshot.jobs(for: id)))
        }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.snapshot.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sessionSections, id: \.id) { group in
                            section(title: group.name,
                                    detail: RunningJobsList.size(
                                        monitor.snapshot.footprint(for: group.id)),
                                    jobs: group.jobs)
                        }
                        if !monitor.snapshot.orphans.isEmpty { orphanSection }
                    }
                    .padding(12)
                }
                // Tall enough for a few sessions, bounded so a machine with a
                // dozen jobs gets a scroller instead of a popover off-screen.
                .frame(maxHeight: 420)
            }
        }
        .frame(width: Self.width)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing running")
                .font(.callout.weight(.medium))
            Text("Servers and builds your sessions start will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(title: String, detail: String?, jobs: [RunningJob]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(jobs) { job in
                JobRow(job: job, quit: { monitor.quit($0) })
            }
        }
    }

    /// The group nothing else on the machine can show you: servers whose session
    /// is gone, still holding memory and ports.
    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not attached to a session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(monitor.snapshot.orphans) { job in
                JobRow(job: job, showsAge: true, quit: { monitor.quit($0) })
            }
        }
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// Compact and deliberately coarse. "4d" is the point being made about an
    /// orphan; "4d 2h 11m" is not.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

/// One job. The Quit button is hover-revealed so a list of six rows doesn't read
/// as six buttons, and absent entirely on the agent's row.
private struct JobRow: View {
    let job: RunningJob
    var showsAge = false
    let quit: (RunningJob) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(job.label)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(job.isAgent ? .secondary : .primary)
                    if let port = job.primaryPort {
                        Text(":\(port)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color(nsColor: .quaternaryLabelColor)))
                    }
                }
                if let detail = subtitle {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            Text(RunningJobsList.size(job.footprint))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Reserve the button's width always, so pointing at a row doesn't
            // shove the sizes sideways.
            Group {
                if job.isKillable, hovering {
                    Button("Quit") { quit(job) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 28, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var subtitle: String? {
        if job.isAgent { return "agent" }
        guard showsAge else { return job.processCount > 1 ? "\(job.processCount) processes" : nil }
        let age = RunningJobsList.age(since: job.startedAt)
        guard let cwd = job.workingDirectory else { return age }
        return "\(age) · \((cwd as NSString).abbreviatingWithTildeInPath)"
    }

    private var tooltip: String {
        var lines = ["\(job.label) (pgid \(job.pgid), \(job.processCount) processes)"]
        if !job.ports.isEmpty {
            lines.append("Listening on " + job.ports.map { ":\($0)" }.joined(separator: " "))
        }
        if let cwd = job.workingDirectory { lines.append(cwd) }
        if job.isAgent { lines.append("This is the session's agent, so it is not quit from here.") }
        return lines.joined(separator: "\n")
    }
}
