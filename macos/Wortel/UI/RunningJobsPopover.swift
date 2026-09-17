import AppKit
import SwiftUI

/// What the session on screen is running, and a way to stop any of it.
///
/// One flat list, no headings. Every row is this session's: it was started
/// here, it is listed here, and closing the session stops it, so a heading
/// naming the session would only repeat the sidebar. Earlier versions grouped
/// by session because they listed every session's servers at once; binding
/// servers to their session removed the reason for the grouping.
///
/// Leftovers that no session owns any more are not listed. They belong to no
/// session, so they have no place in a list that is about one, and they only
/// come from before servers were bound to their sessions (or from a `setsid`).
///
/// Laid out with room, the way Proxyman's and Xcode's status popovers are: a
/// header, two-line rows whose second line is the address, and controls that
/// are always where you expect them. The first cut borrowed the branch
/// switcher's dense single-line rows, and a list of two servers read as cramped
/// rather than calm.
struct RunningJobsList: View {
    let monitor: ProcessMonitor
    /// The session this popover is about.
    let session: UUID
    let dismiss: () -> Void

    static let width: CGFloat = 360

    /// About five rows before it scrolls.
    static let maxListHeight: CGFloat = 300

    /// The outer margin everything lines up on: header, rows' content, footer.
    static let inset: CGFloat = 16

    /// The row under the pointer, by job id.
    ///
    /// **Not `pgid`.** A process group can hold more than one job, so two rows
    /// can share one, and keying the highlight on it lit both at once.
    @State private var hovered: pid_t?

    /// This session's jobs, and what it started that has already been filed
    /// as an orphan (it is still this session's to stop).
    private var snapshot: RunningJobsSnapshot { monitor.snapshot.scoped(to: session) }

    /// This session's work, detached or not.
    private var rows: [RunningJob] { snapshot.work + snapshot.orphans }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if rows.isEmpty {
                Text("Nothing running in this session")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let (servers, others) = RunningJobs.partitioned(rows)
                        ForEach(servers) { job in row(job) }
                        if !servers.isEmpty, !others.isEmpty {
                            // A heading only when there are two kinds to tell
                            // apart; a list of one kind is its own heading.
                            Text("Other processes")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                        }
                        ForEach(others) { job in row(job) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: Self.maxListHeight)
            }

            if !snapshot.agents.isEmpty {
                Divider()
                    .padding(.horizontal, Self.inset)
                agentFooter
            }
        }
        .frame(width: Self.width)
    }

    private func row(_ job: RunningJob) -> some View {
        JobRow(job: job,
               isHighlighted: hovered == job.id,
               open: { open(job) },
               quit: { monitor.quit(job) },
               hover: { inside in
                   if inside {
                       hovered = job.id
                   } else if hovered == job.id {
                       // Only if it is still ours: the enter
                       // for the next row arrives before this
                       // row's exit, and clearing
                       // unconditionally blanks the highlight
                       // as the pointer slides down the list.
                       hovered = nil
                   }
               })
    }

    /// What this is and what it costs, before the detail.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: headline)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if !rows.isEmpty {
                Text(verbatim: RunningJobsList.size(rows.reduce(0) { $0 + $1.footprint }))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var headline: String {
        let serving = rows.filter { $0.primaryPort != nil }.count
        let other = rows.count - serving
        switch (serving, other) {
        case (0, 0): return "Running"
        case (0, _): return other == 1 ? "1 job running" : "\(other) jobs running"
        case (_, 0): return serving == 1 ? "1 server running" : "\(serving) servers running"
        default:
            let servers = serving == 1 ? "1 server" : "\(serving) servers"
            let jobs = other == 1 ? "1 job" : "\(other) jobs"
            return "\(servers), \(jobs)"
        }
    }

    /// One accounting line, so leaving the agent out of the list above doesn't
    /// quietly leave its memory unexplained.
    private var agentFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: snapshot.agents.count == 1
                 ? "Agent" : "\(snapshot.agents.count) agents")
            Spacer(minLength: 8)
            Text(verbatim: RunningJobsList.size(snapshot.agentFootprint))
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 11)
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
}

/// One job: its name, and underneath, where it is and what it costs.
private struct JobRow: View {
    let job: RunningJob
    let isHighlighted: Bool
    let open: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void

    /// Briefly true after Copy, so the button says it worked.
    @State private var copied = false

    /// Whether clicking the row goes anywhere.
    private var isOpenable: Bool { job.localURL != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Serving something, or merely running. The one bit of state worth a
            // glyph: a build and a web server look identical in a list of names.
            Circle()
                .fill(job.primaryPort != nil
                      ? AnyShapeStyle(Color(nsColor: .systemGreen))
                      : AnyShapeStyle(.quaternary))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                // Tail, not middle: a command reads from the left, and middle
                // truncation turned `quick.js serve dist --dir …` into
                // `quick.js serve di…-chat-prototype`, which names nothing.
                Text(verbatim: job.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle
            }
            // **No layout priority.** The name is the only thing here that can
            // usefully shrink, so it is the one that gives way.
            .frame(maxWidth: .infinity, alignment: .leading)
            // One sentence for VoiceOver rather than a name, an address, a size
            // and two middle dots read out as separate fragments. The buttons
            // stay their own elements beside it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenDescription)
            .accessibilityAddTraits(isOpenable ? .isButton : [])
            .accessibilityHint(isOpenable ? "Opens in your browser" : "")
            .accessibilityAction { if isOpenable { open() } }

            HStack(spacing: 2) {
                if let address = job.localAddress {
                    RowIconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                  label: "Copy \(address)") { copy(address) }
                }
                if job.isKillable {
                    RowIconButton(symbol: "stop.fill", label: "Stop \(job.label)",
                                  isDestructive: true, action: quit)
                }
            }
            // Quiet at rest, full strength under the pointer. Present either way,
            // so nothing shifts as the pointer moves down the list.
            .opacity(isHighlighted ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHighlighted ? 0.06 : 0))
        }
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        // No cursor change. A pointing hand over a list row is a web idiom:
        // macOS keeps the arrow over clickable rows everywhere, Finder and Xcode
        // included, and says "this does something" with the highlight instead.
        .onHover { hover($0) }
        // Left-click opens; the buttons keep their own clicks because they are
        // real Buttons drawn over this.
        .onTapGesture { if isOpenable { open() } }
        .overlay(RightClickCatcher(onRightClick: {}, makeMenu: makeMenu))
        .help(tooltip)
    }

    /// Where it is, what it costs, and whether it has left the shell.
    private var subtitle: some View {
        HStack(spacing: 5) {
            if let address = job.localAddress {
                // Every port it holds, not just the lowest: one row can serve
                // several, and naming one of them hid the others.
                //
                // Verbatim, because `Text(":\(port)")` formats the number for
                // the locale, which is how :3000 came out as ":3,000".
                let extra = job.shownPorts.filter { $0 != job.primaryPort }
                Text(verbatim: ([address] + extra.map { ":\($0)" }).joined(separator: " "))
                    .foregroundStyle(isHighlighted && isOpenable
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.secondary))
                    // An address is indivisible: it takes its width first.
                    .fixedSize()
                    .layoutPriority(1)
                dot
            }
            Text(verbatim: RunningJobsList.size(job.footprint))
            if job.detached || job.lastSessionID != nil {
                dot
                Text("Detached")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    /// "vite dev, port 3000, 14.8 MB, detached from the shell." Ports spelled
    /// as ports, because ":3000" read aloud is "colon three thousand".
    private var spokenDescription: String {
        var parts = [job.label]
        let ports = job.shownPorts
        if !ports.isEmpty {
            parts.append((ports.count == 1 ? "port " : "ports ")
                         + ports.map(String.init).joined(separator: ", "))
        }
        parts.append(RunningJobsList.size(job.footprint))
        if job.detached || job.lastSessionID != nil { parts.append("detached from the shell") }
        return parts.joined(separator: ", ")
    }

    private var dot: some View {
        Text(verbatim: "\u{00B7}").accessibilityHidden(true)
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
            menu.addItem(ClosureMenuItem(title: "Stop", handler: quit))
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "Nothing to do", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    private func copy(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private var tooltip: String {
        var lines = ["\(job.label): \(job.processCount) processes, pgid \(job.pgid)"]
        if !job.ports.isEmpty {
            lines.append("Listening on " + job.ports.map { ":\($0)" }.joined(separator: " "))
        }
        if let cwd = job.workingDirectory { lines.append(cwd) }
        if let address = job.localAddress { lines.append("Click to open \(address)") }
        return lines.joined(separator: "\n")
    }
}

/// A small round icon button that lights up under the pointer, the kind
/// Proxyman puts beside a value to copy it.
private struct RowIconButton: View {
    let symbol: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered && isDestructive
                                 ? AnyShapeStyle(Color(nsColor: .systemRed))
                                 : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(isHovered ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
