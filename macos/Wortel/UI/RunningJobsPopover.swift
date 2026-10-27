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
/// Laid out as the rest of the chrome is: a small grey heading, rows with the
/// name over its address and memory in grey, and the row's buttons only under
/// the pointer, as a sidebar row's "…" and "×" are. Sized close to a menu
/// (12pt names, 11pt detail), because that's how it's used: open, pick, gone.
/// (It was a roomy list at 13pt with a bold title, after Proxyman's and Xcode's
/// popovers, which read as a different app.)
struct RunningJobsList: View {
    let monitor: ProcessMonitor
    /// The session this popover is about.
    let session: UUID
    /// Show an address as a tab in the session, beside what's serving it.
    let openInTab: (URL) -> Void
    let dismiss: () -> Void

    static let width: CGFloat = 280

    /// About five rows before it scrolls.
    static let maxListHeight: CGFloat = 300

    /// The card's margin around the rows; their pills sit this far in.
    static let margin: CGFloat = 5
    /// Where text starts inside a row's pill, which the heading and the
    /// footer line up on too.
    static let textInset: CGFloat = 10

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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let (servers, others) = RunningJobs.partitioned(rows)
                        ForEach(servers) { job in row(job) }
                        if !servers.isEmpty, !others.isEmpty {
                            // A heading only when there are two kinds to tell
                            // apart; a list of one kind is its own heading.
                            heading("Other processes")
                                .padding(.top, 6)
                        }
                        ForEach(others) { job in row(job) }
                    }
                }
                .frame(maxHeight: Self.maxListHeight)
            }

            if !snapshot.agents.isEmpty {
                Divider()
                    .padding(.horizontal, Self.textInset)
                    .padding(.vertical, 3)
                agentFooter
            }
        }
        .padding(Self.margin)
        .frame(width: Self.width)
    }

    private func row(_ job: RunningJob) -> some View {
        JobRow(job: job,
               isHighlighted: hovered == job.id,
               open: { open(job) },
               openInTab: { openAsTab(job) },
               openInBrowser: { openInBrowser(job) },
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

    /// What this is and what it costs, before the detail. A heading in the
    /// grey the sidebar's and the new page's are, not a bold title.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: headline)
            Spacer(minLength: 8)
            if !rows.isEmpty {
                Text(verbatim: RunningJobsList.size(rows.reduce(0) { $0 + $1.footprint }))
                    .monospacedDigit()
            }
            // Only with two or more: for one, its own stop button is the same
            // thing. The agent isn't a row, so it's never part of "all".
            if stoppable.count > 1 {
                StopAllButton { for job in stoppable { monitor.quit(job) } }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Self.textInset)
        .padding(.top, 4)
        .padding(.bottom, 3)
    }

    /// What Stop All stops: every row a row's own stop button could.
    private var stoppable: [RunningJob] { rows.filter(\.isKillable) }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Self.textInset)
            .padding(.vertical, 3)
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
                .font(.system(size: 10))
                .frame(width: 8)
                .accessibilityHidden(true)
            Text(verbatim: snapshot.agents.count == 1
                 ? "Agent" : "\(snapshot.agents.count) agents")
            Spacer(minLength: 8)
            Text(verbatim: RunningJobsList.size(snapshot.agentFootprint))
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Self.textInset)
        .frame(height: 22)
    }

    /// Show the address as a tab, or in your browser if that's where servers
    /// go (`BrowserTabs.opensServersInDefaultBrowser`), and get out of the
    /// way: you clicked through to it, so the popover has done its job.
    private func open(_ job: RunningJob) {
        guard let url = job.localURL else { return }
        if BrowserTabs.opensServersInDefaultBrowser {
            NSWorkspace.shared.open(url)
        } else {
            openInTab(url)
        }
        dismiss()
    }

    private func openAsTab(_ job: RunningJob) {
        guard let url = job.localURL else { return }
        openInTab(url)
        dismiss()
    }

    private func openInBrowser(_ job: RunningJob) {
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
    let openInTab: () -> Void
    let openInBrowser: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void

    /// Briefly true after Copy, so the button says it worked.
    @State private var copied = false

    /// Whether clicking the row goes anywhere.
    private var isOpenable: Bool { job.localURL != nil }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // The dot in the name's line, so it centres on the name rather
                // than on the two lines; the detail hangs under the name.
                HStack(spacing: 8) {
                    // Serving something, or merely running. The one bit of state
                    // worth a glyph: a build and a web server look identical in
                    // a list of names.
                    Circle()
                        .fill(job.primaryPort != nil
                              ? AnyShapeStyle(Color(nsColor: .systemGreen))
                              : AnyShapeStyle(.quaternary))
                        .frame(width: 6, height: 6)
                        .frame(width: 8)
                        .accessibilityHidden(true)
                    // Tail, not middle: a command reads from the left, and
                    // middle truncation turned `quick.js serve dist --dir …`
                    // into `quick.js serve di…-chat-prototype`, which names
                    // nothing.
                    Text(verbatim: job.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                subtitle
                    .padding(.leading, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One sentence for VoiceOver rather than a name, an address and a
            // size read out as separate fragments. The buttons stay their own
            // elements beside it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenDescription)
            .accessibilityAddTraits(isOpenable ? .isButton : [])
            .accessibilityHint(isOpenable ? (BrowserTabs.opensServersInDefaultBrowser
                                             ? "Opens in your browser" : "Opens in a tab") : "")
            .accessibilityAction { if isOpenable { open() } }

            // Under the pointer only, as a sidebar row's "…" and "×" are.
            HStack(spacing: 0) {
                if job.localAddress != nil {
                    RowIconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                  label: "Copy \(job.localAddress ?? "")") { copy() }
                }
                if job.isKillable {
                    RowIconButton(symbol: "stop.fill", label: "Stop \(job.label)",
                                  isDestructive: true, action: quit)
                }
            }
            .opacity(isHighlighted ? 1 : 0)
        }
        .padding(.leading, RunningJobsList.textInset)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: isHighlighted ? Chrome.hoverFill : .clear))
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

    /// "localhost:3000", with any further ports it holds: ":3000 :3001".
    /// Verbatim, because `Text(":\(port)")` formats the number for the locale,
    /// which is how :3000 came out as ":3,000".
    private var address: String? {
        guard let address = job.localAddress else { return nil }
        let extra = job.shownPorts.filter { $0 != job.primaryPort }
        return ([address] + extra.map { ":\($0)" }).joined(separator: " ")
    }

    /// Where it is, what it costs, and whether it has left the shell.
    private var subtitle: some View {
        HStack(spacing: 4) {
            if let address {
                // Every port it holds, not just the lowest: one row can serve
                // several, and naming one of them hid the others.
                Text(verbatim: address)
                    .foregroundStyle(isHighlighted && isOpenable
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.tertiary))
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
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    private var dot: some View {
        Text(verbatim: "\u{00B7}").accessibilityHidden(true)
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
            // Both, whichever a click does: the menu is where you get the
            // other one once.
            menu.addItem(ClosureMenuItem(title: "Open in Tab", handler: openInTab))
            menu.addItem(ClosureMenuItem(title: "Open in Browser", handler: openInBrowser))
            let always = ClosureMenuItem(title: "Always Open in Browser") {
                BrowserTabs.opensServersInDefaultBrowser.toggle()
            }
            always.state = BrowserTabs.opensServersInDefaultBrowser ? .on : .off
            menu.addItem(always)
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

    private func copy() {
        guard let address = job.localAddress else { return }
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
        if let address = job.localAddress {
            lines.append("Click to open \(address) "
                         + (BrowserTabs.opensServersInDefaultBrowser ? "in your browser" : "in a tab"))
        }
        return lines.joined(separator: "\n")
    }
}

/// A small round icon button that lights up under the pointer, the kind
/// Proxyman puts beside a value to copy it.
/// The heading's "Stop All": as quiet as the heading until the pointer is on
/// it, then red as a row's stop button turns. No confirmation, as a row's
/// stop asks none: a server is one command to start again.
private struct StopAllButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Stop All")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(Color(nsColor: .systemRed))
                                           : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: isHovered ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Stop everything listed")
    }
}

private struct RowIconButton: View {
    let symbol: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovered && isDestructive
                                 ? AnyShapeStyle(Color(nsColor: .systemRed))
                                 : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: isHovered ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
