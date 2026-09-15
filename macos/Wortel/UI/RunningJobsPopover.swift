import AppKit
import SwiftUI

/// What the sessions are running, and a way to stop any of it.
///
/// Deliberately the same list as the branch switcher: caption section headings,
/// callout rows, a row inset the highlight sits inside, and the trailing detail
/// in tertiary caption. Two popovers off the same toolbar that answered their
/// questions in two different visual languages read as two different apps.
///
/// The editing is the design. The first version listed everything it could see,
/// and on a real machine that was eleven `claude` rows and five `zsh -l` rows
/// with the two dev servers it exists for buried in the middle. Only work is
/// listed; agents get one accounting line at the bottom; sessions running
/// nothing are not mentioned.
struct RunningJobsList: View {
    let monitor: ProcessMonitor
    /// Sessions are named in `SessionManager`; this view only needs to print
    /// them, so it takes a lookup rather than the whole manager.
    let sessionName: (UUID) -> String?
    let dismiss: () -> Void

    /// A touch wider than the branch list's 300: these rows carry a name, a port
    /// and a size where that one carries a name and an upstream.
    static let width: CGFloat = 330

    /// Roughly eight rows, same as the branch list. Tall enough to browse, short
    /// enough not to become the tallest thing on screen.
    static let maxListHeight: CGFloat = 264

    /// The row under the pointer, by job id.
    ///
    /// **Not `pgid`.** A process group can hold more than one job, so two rows
    /// can share one, and keying the highlight on it lit both at once.
    @State private var hovered: pid_t?

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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.id) { group in
                            section(group.name, jobs: group.jobs, showsDetail: false)
                        }
                        section("Not attached to a session",
                                jobs: snapshot.orphans, showsDetail: true)
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: Self.maxListHeight)
            } else {
                Text("Nothing running")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            if !snapshot.agents.isEmpty {
                Divider()
                agentFooter
            }
        }
        .frame(width: Self.width)
    }

    /// One accounting line, so leaving the agents out of the list above doesn't
    /// quietly leave three gigabytes unexplained.
    private var agentFooter: some View {
        HStack(spacing: 0) {
            Text(verbatim: snapshot.agents.count == 1
                 ? "1 agent" : "\(snapshot.agents.count) agents")
            Spacer(minLength: 8)
            Text(verbatim: RunningJobsList.size(snapshot.agentFootprint))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func section(_ title: String, jobs: [RunningJob],
                         showsDetail: Bool) -> some View {
        if !jobs.isEmpty {
            // A session can be named from its first prompt, so this heading is
            // sometimes an entire sentence. It gets one line and an ellipsis
            // rather than running to the edge of the popover.
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(jobs) { job in
                JobRow(job: job,
                       showsDetail: showsDetail,
                       isHighlighted: hovered == job.id,
                       open: { open(job) },
                       quit: { monitor.quit(job) },
                       hover: { inside in
                           if inside {
                               hovered = job.id
                           } else if hovered == job.id {
                               // Only if it is still ours: the enter for the next
                               // row arrives before this row's exit, and clearing
                               // unconditionally blanks the highlight as the
                               // pointer slides down the list.
                               hovered = nil
                           }
                       })
            }
        }
    }

    /// Hand the address to the browser and get out of the way: you clicked
    /// through to somewhere else, so the popover has done its job.
    private func open(_ job: RunningJob) {
        guard let url = job.localURL else { return }
        NSWorkspace.shared.open(url)
        dismiss()
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

/// One job. Metrics deliberately identical to `BranchOptionRow`.
private struct JobRow: View {
    let job: RunningJob
    let showsDetail: Bool
    let isHighlighted: Bool
    let open: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void

    /// Whether clicking the row goes anywhere.
    private var isOpenable: Bool { job.localURL != nil }

    var body: some View {
        HStack(spacing: 6) {
            // Serving something, or merely running. The one bit of state worth a
            // glyph: a build and a web server look identical in a list of names.
            Image(systemName: job.primaryPort != nil ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(dotStyle)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 0) {
                // Tail, not middle: a command reads from the left, and middle
                // truncation turned `quick.js serve dist --dir …` into
                // `quick.js serve di…-chat-prototype`, which names nothing.
                Text(verbatim: job.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsDetail, let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // **No layout priority.** The label used to claim it, which left the
            // port nothing to lay out in: `:13337` came out stacked one digit per
            // line down the row. The label is the only thing here that can
            // usefully shrink, so it is the one that gives way.
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if !job.shownPorts.isEmpty {
                // Every port it holds, not just the lowest. One row can cover a
                // job serving several, and naming one of them hid the others.
                //
                // `Text(":\(port)")` reads as a LocalizedStringKey and formats
                // the number for the locale, which is how :3000 came out as
                // ":3,000". A port is an address, not a quantity.
                HStack(spacing: 2) {
                    Text(verbatim: job.shownPorts.map { ":\($0)" }.joined(separator: " "))
                        .font(.caption.monospacedDigit())
                    // Only while pointed at, so a list at rest stays a list of
                    // facts rather than a column of buttons.
                    if isHighlighted, isOpenable {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                // An address is indivisible: it wraps or truncates into
                // nonsense, so it takes its width before anything else does.
                .fixedSize()
                .layoutPriority(2)
                .foregroundStyle(secondaryStyle)
            }

            trailing
                .font(.caption.monospacedDigit())
                .fixedSize()
                .frame(width: 58, alignment: .trailing)
                .layoutPriority(2)
        }
        .font(.callout)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 6)
            }
        }
        // No cursor change. A pointing hand over a list row is a web idiom:
        // macOS keeps the arrow over clickable rows everywhere, Finder and Xcode
        // included, and says "this does something" with the highlight instead.
        // It was also a `push()`/`pop()` pair that a row disappearing mid-hover
        // would leave unbalanced, which is a cursor stuck app-wide.
        .onHover { hover($0) }
        // Left-click opens; the Quit button above keeps its own click because it
        // is a real Button drawn over this.
        .onTapGesture { if isOpenable { open() } }
        .overlay(RightClickCatcher(onRightClick: {}, makeMenu: makeMenu))
        .help(tooltip)
    }

    /// Everything you might want to do with a listening process, including the
    /// things a browser cannot do for you.
    ///
    /// `Copy Address` is the one that matters for the rows this feature cannot
    /// classify: a database, a gRPC server or a message broker is not something
    /// to open, but `localhost:6379` is exactly what its client wants.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if isOpenable {
            menu.addItem(ClosureMenuItem(title: "Open in Browser", handler: open))
        }
        if let address = job.localAddress {
            menu.addItem(ClosureMenuItem(title: "Copy Address", handler: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }))
        }
        if let cwd = job.workingDirectory {
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder", handler: {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: cwd)])
            }))
        }
        if job.isKillable {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: "Quit", handler: quit))
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "Nothing to do", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// The size, or the way to stop it. Swapped rather than shown side by side:
    /// a fixed-width slot keeps the column from shifting under the pointer, and
    /// a row that always shows a button reads as a form to fill in.
    @ViewBuilder
    private var trailing: some View {
        if isHighlighted, job.isKillable {
            Button("Quit", action: quit)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .fontWeight(.medium)
        } else {
            Text(verbatim: RunningJobsList.size(job.footprint))
                .foregroundStyle(secondaryStyle)
        }
    }

    private var dotStyle: AnyShapeStyle {
        if isHighlighted { return AnyShapeStyle(.white) }
        return job.primaryPort != nil
            ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary)
    }

    private var secondaryStyle: AnyShapeStyle {
        isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary)
    }

    /// Only the orphans carry one: how long it has been there and which project
    /// it came out of, which is the whole of what makes it recognisable once its
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
        if let address = job.localAddress { lines.append("Click to open \(address)") }
        return lines.joined(separator: "\n")
    }
}
