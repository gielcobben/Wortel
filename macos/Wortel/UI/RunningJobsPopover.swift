import SwiftUI

/// What the sessions are running, and a way to stop any of it.
///
/// Shaped like the battery menu's "Using Significant Energy" rather than like
/// Activity Monitor: a short answer to "what is holding my machine", not a
/// process browser. Which means the editing is the design. The first version
/// listed everything it could see, and on a real machine that was five `claude`
/// rows and five `zsh -l` rows with the two dev servers it exists for buried in
/// the middle.
///
/// So: only work is listed. Agents are the session's whole point rather than
/// something you meant to stop, and they get one accounting line at the bottom
/// instead of a row each. Sessions running nothing are not mentioned at all.
struct RunningJobsList: View {
    let monitor: ProcessMonitor
    /// Sessions are named in `SessionManager`; this view only needs to print
    /// them, so it takes a lookup rather than the whole manager.
    let sessionName: (UUID) -> String?
    let dismiss: () -> Void

    /// Wide enough for `wrangler dev --env=dev --local` beside a port and a
    /// size. `NSPopover` sizes to what it is handed, so this frame is what gives
    /// it one at all.
    static let width: CGFloat = 360

    private var snapshot: RunningJobsSnapshot { monitor.snapshot }

    /// Sessions that are actually running something, biggest first.
    private var sections: [(id: UUID, name: String, jobs: [RunningJob])] {
        var seen: Set<UUID> = []
        var sections: [(id: UUID, name: String, jobs: [RunningJob])] = []
        for job in snapshot.work {
            guard let id = job.sessionID, seen.insert(id).inserted else { continue }
            sections.append((id, sessionName(id) ?? "Session", snapshot.work(for: id)))
        }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.hasWork {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.id) { group in
                            section(group.name, jobs: group.jobs, showsDetail: false)
                        }
                        if !snapshot.orphans.isEmpty {
                            section("Not attached to a session",
                                    jobs: snapshot.orphans, showsDetail: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                // Enough for a few sessions; beyond that it scrolls rather than
                // running off the bottom of the screen.
                .frame(maxHeight: 380)
            } else {
                empty
            }
            if !snapshot.agents.isEmpty { agentFooter }
        }
        .frame(width: Self.width)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing running")
                .font(.callout.weight(.semibold))
            Text("Servers and builds your sessions start show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One accounting line, so leaving the agents out of the list above doesn't
    /// quietly leave a gigabyte unexplained.
    private var agentFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(snapshot.agents.count == 1
                     ? "1 agent" : "\(snapshot.agents.count) agents")
                Spacer()
                Text(RunningJobsList.size(snapshot.agentFootprint))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder
    private func section(_ title: String, jobs: [RunningJob],
                         showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(jobs) { job in
                    JobRow(job: job, showsDetail: showsDetail) { monitor.quit($0) }
                }
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

/// One job.
///
/// The row is a menu row, so it highlights under the pointer and the Quit button
/// only appears there: six rows each carrying a visible button reads as a form to
/// fill in rather than a list to glance at.
private struct JobRow: View {
    let job: RunningJob
    var showsDetail = false
    let quit: (RunningJob) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Serving something, or merely running. The one bit of state worth a
            // glyph: a build and a web server look identical in a list of names.
            Circle()
                .fill(job.primaryPort != nil ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsDetail, let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            if let port = job.primaryPort {
                Text(":\(port)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    .fixedSize()
            }

            Spacer(minLength: 8)

            if hovering, job.isKillable {
                Button("Quit") { quit(job) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(RunningJobsList.size(job.footprint))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    /// Only the orphans carry one: how long it has been there and which project
    /// it came out of, which is the whole of what makes it recognisable when its
    /// session is long gone.
    private var detail: String? {
        let age = RunningJobsList.age(since: job.startedAt)
        guard let cwd = job.workingDirectory else { return age }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? age : "\(age) in \(name)"
    }

    private var tooltip: String {
        var lines = ["\(job.label) — \(job.processCount) processes, pgid \(job.pgid)"]
        if !job.ports.isEmpty {
            lines.append("Listening on " + job.ports.map { ":\($0)" }.joined(separator: " "))
        }
        if let cwd = job.workingDirectory { lines.append(cwd) }
        return lines.joined(separator: "\n")
    }
}
