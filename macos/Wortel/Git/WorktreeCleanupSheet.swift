import AppKit
import SwiftUI

/// What is using a worktree, as far as the app can tell: open sessions standing
/// in it, and any process of yours whose working directory is inside it.
///
/// Neither is visible to git, and both are the difference between "clean" and
/// "safe": an agent with nothing written yet is a clean worktree you must not
/// delete under it.
struct WorktreeUsage: Sendable {
    /// Each open session's name and the directories it stands in.
    struct SessionPlace: Sendable {
        let name: String
        let paths: [String]
        let shellPIDs: [pid_t]
        /// Closed and waiting in its folder's Archived fold: no shell, but
        /// restoring it starts one in its worktree, on its branch.
        var isArchived = false
    }

    /// Your processes and where each one stands, read once and asked about
    /// every worktree: reading every process's directory is a syscall each,
    /// and a pass over twenty worktrees used to do it twenty times.
    struct Processes: Sendable {
        struct Entry: Sendable {
            let pid: pid_t
            let name: String
            let cwd: String
        }
        let entries: [Entry]
        let parentOf: [pid_t: pid_t]

        /// Off the main thread: it reads the whole process table.
        nonisolated static func read() -> Processes {
            let table = ProcessTable.snapshot()
            var parentOf: [pid_t: pid_t] = [:]
            for entry in table { parentOf[entry.pid] = entry.ppid }
            let me = getuid()
            let app = getpid()
            var entries: [Entry] = []
            // Not the app or its own children: the git it runs to inspect (and
            // the header's change counts) stands in these folders too, and
            // would otherwise read as "git, running there".
            for entry in table where entry.uid == me && entry.pid != app && entry.ppid != app {
                guard let cwd = ProcessTable.workingDirectory(of: entry.pid) else { continue }
                entries.append(Entry(pid: entry.pid, name: entry.name, cwd: cwd))
            }
            return Processes(entries: entries, parentOf: parentOf)
        }

        func tree(under roots: [pid_t]) -> Set<pid_t> {
            Self.tree(under: roots, parentOf: parentOf)
        }

        nonisolated static func tree(under roots: [pid_t], parentOf: [pid_t: pid_t]) -> Set<pid_t> {
            var found = Set(roots)
            for pid in parentOf.keys where roots.contains(where: {
                ProcessTable.isDescendant(pid, of: $0, parentOf: parentOf)
            }) {
                found.insert(pid)
            }
            return found
        }
    }

    let sessions: [SessionPlace]
    /// Processes not to count: the session being closed, whose shell and
    /// children are on their way out. Taken when the sheet opens, while they
    /// still hang from its shell; once it's gone they're reparented and no
    /// longer look like anyone's.
    let excludedPIDs: Set<pid_t>

    /// `countingArchived`: archived sessions' worktrees count as in use too.
    /// For Bring Here, which would otherwise take an archived session's
    /// branch and Trash the folder it's waiting to be restored in. Not for
    /// the cleanup sheet, whose Delete Worktree… is how an archived one goes
    /// on purpose, nor for the close that is archiving one right now.
    ///
    /// Where a session's git panes are *looking* (`gitCheckout`) is not a
    /// place it stands: only its shell's directories count.
    @MainActor
    init(manager: SessionManager, excluding closing: Session? = nil, countingArchived: Bool = false) {
        sessions = manager.sessions.filter { $0 !== closing }.map { session in
            SessionPlace(
                name: session.name,
                paths: [session.cwd, session.originCwd].compactMap { $0 },
                shellPIDs: [session.shellPID].compactMap { $0 } + session.sideShells.map(\.pid))
        } + (countingArchived ? manager.archived.map {
            SessionPlace(name: $0.leafName, paths: [$0.checkout], shellPIDs: [], isArchived: true)
        } : [])
        if let closing {
            let roots = [closing.shellPID].compactMap { $0 } + closing.sideShells.map(\.pid)
            // Parent links only, no directories: this runs on the main thread
            // as the sheet opens, and one sysctl is all it needs.
            var parentOf: [pid_t: pid_t] = [:]
            for entry in ProcessTable.snapshot() { parentOf[entry.pid] = entry.ppid }
            excludedPIDs = roots.isEmpty ? [] : Processes.tree(under: roots, parentOf: parentOf)
        } else {
            excludedPIDs = []
        }
    }

    /// Who is using `path`, for the report.
    nonisolated func users(of path: String, in processes: Processes) -> [String] {
        let base = WorktreeCleanup.canonical(path)
        let inside: (String) -> Bool = { candidate in
            let resolved = WorktreeCleanup.canonical(candidate)
            return resolved == base || resolved.hasPrefix(base + "/")
        }
        var users: [String] = []
        var accounted = excludedPIDs
        for session in sessions where session.paths.contains(where: inside) {
            users.append(session.isArchived
                         ? "the archived session \u{201c}\(session.name)\u{201d}"
                         : "the session \u{201c}\(session.name)\u{201d}")
            // Its own processes are that session, already said.
            accounted.formUnion(processes.tree(under: session.shellPIDs))
        }
        var names: [String] = []
        for entry in processes.entries where !accounted.contains(entry.pid) && inside(entry.cwd) {
            if !names.contains(entry.name) { names.append(entry.name) }
        }
        if !names.isEmpty {
            let shown = names.prefix(3).joined(separator: ", ")
            let more = names.count > 3 ? " and \(names.count - 3) more" : ""
            users.append("\(shown)\(more), running there")
        }
        return users
    }
}

/// The rows behind the sheet: each worktree, its report once inspected, and
/// what you've chosen to do with it.
@Observable
@MainActor
final class WorktreeCleanupModel {
    struct Row: Identifiable {
        let path: String
        /// The branch, read from the worktree's own files as the row is made
        /// (`GitWorktree.checkedOutBranch`), so it has its real name from the
        /// start instead of its folder's, and doesn't change name and place in
        /// the list when its check lands.
        let branchHint: String?
        var report: WorktreeReport?
        /// Move the folder to the Trash.
        var remove = false
        /// On its way to the Trash right now.
        var removing = false
        /// Why the last attempt kept it, when it did.
        var error: String?
        var id: String { path }

        init(path: String) {
            self.path = path
            branchHint = GitWorktree.checkedOutBranch(at: path)
        }
    }

    enum Mode {
        /// Every worktree Wortel made.
        case cleanUp
        /// One archived session's worktree, which deleting the session takes
        /// with it (the archived row's Delete Worktree…).
        case deleting(ArchivedSession)
    }

    let mode: Mode
    private(set) var rows: [Row] = []
    private(set) var isLoading = true
    private(set) var isWorking = false
    /// Delete the branches of what's removed as well, for the ones that can
    /// go without losing anything: Wortel's own (`worktree/`), with every
    /// commit also on another branch or a remote. One switch for the sheet,
    /// not one per row; a branch with commits found nowhere else is always
    /// kept, and deleting it is the terminal's job.
    var deleteBranches = true
    @ObservationIgnored private let manager: SessionManager
    @ObservationIgnored private var knownRepos: [String] = []
    @ObservationIgnored private var usage: WorktreeUsage
    @ObservationIgnored var dismiss: () -> Void = {}

    init(mode: Mode, manager: SessionManager) {
        self.mode = mode
        self.manager = manager
        usage = WorktreeUsage(manager: manager)
    }

    var deletingItem: ArchivedSession? {
        if case .deleting(let item) = mode { return item }
        return nil
    }

    var title: String {
        if let item = deletingItem { return "Delete \u{201c}\(item.leafName)\u{201d}?" }
        return "Clean Up Worktrees"
    }

    var removableCount: Int { rows.filter(\.remove).count }

    /// How many rows have been checked, for the footer while it's going on.
    var checkedCount: Int { rows.filter { $0.report != nil }.count }
    var isChecking: Bool { !isLoading && rows.contains { $0.report == nil } }

    /// How many worktrees are checked at once. Each is a full `git status`,
    /// which in a large repository is seconds, and one after the other was
    /// minutes for a handful; a few at once is what the disk can take
    /// without the checks slowing each other down.
    private static let parallelChecks = 4

    /// The rows first, the checks after. Everything on disk is listed at
    /// once, by name (a directory listing, no git), and checked a few at a
    /// time, each row filling in as its own check lands. What only git knows
    /// about (a registration whose folder is gone) is found alongside and
    /// added when it's found.
    func load() async {
        if let item = deletingItem {
            rows = [Row(path: item.checkout)]
            isLoading = false
            knownRepos = await Self.repos(of: manager)
            await check(rows.map(\.path))
            return
        }
        rows = WorktreeCleanup.folders().map { Row(path: $0) }
        isLoading = false
        knownRepos = await Self.repos(of: manager)
        async let onDisk: Void = check(rows.map(\.path))
        let all = await WorktreeCleanup.discover(knownRepos: knownRepos)
        let added = all.filter { path in !rows.contains { $0.path == path } }
        rows += added.map { Row(path: $0) }
        await onDisk
        await check(added)
        // A folder for a repo with nothing left in it is a trace too.
        WorktreeCleanup.removeEmptyRepoFolders()
    }

    private func check(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let usage = self.usage
        let repos = knownRepos
        let urgent = deletingItem != nil
        let processes = await Task.detached { WorktreeUsage.Processes.read() }.value
        await withTaskGroup(of: WorktreeReport.self) { group in
            var queue = paths[...]
            var running = 0
            while running < Self.parallelChecks, let path = queue.popFirst() {
                let users = usage.users(of: path, in: processes)
                group.addTask {
                    await WorktreeCleanup.inspect(path: path, knownRepos: repos, usedBy: users, urgent: urgent)
                }
                running += 1
            }
            for await report in group {
                if let index = rows.firstIndex(where: { $0.path == report.path }) {
                    rows[index].report = report
                    // The default is always the choice that loses nothing.
                    rows[index].remove = report.verdict != .blocked
                }
                if let path = queue.popFirst() {
                    let users = usage.users(of: path, in: processes)
                    group.addTask {
                        await WorktreeCleanup.inspect(path: path, knownRepos: repos, usedBy: users, urgent: urgent)
                    }
                }
            }
        }
    }

    func setRemove(_ path: String, _ on: Bool) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[index].remove = on
        // Ticked again after a failed attempt: that's a retry, and the old
        // reason is history until it fails again.
        if on { rows[index].error = nil }
    }

    /// Whether removing this row also deletes its branch.
    func deletesBranch(_ row: Row) -> Bool {
        deleteBranches && row.report?.branchIsDeletable == true
    }

    /// Whether the branch switch would affect anything on screen at all.
    var offersBranchDeletion: Bool {
        rows.contains { $0.remove && $0.report?.branchIsDeletable == true }
    }

    /// Remove what's ticked. Each is re-checked first (see
    /// `WorktreeCleanup.remove`); what's kept stays listed with the reason.
    func removeSelected() async {
        isWorking = true
        defer { isWorking = false }
        // Read fresh, once: things may have started since the sheet opened.
        let processes = await Task.detached { WorktreeUsage.Processes.read() }.value
        // One at a time, on purpose, unlike the checks: removing a worktree
        // and deleting its branch write the repository's shared files, and
        // two at once trip over each other's locks. Each row says when it's
        // the one going.
        for row in rows where row.remove {
            if let index = rows.firstIndex(where: { $0.path == row.path }) { rows[index].removing = true }
            let users = usage.users(of: row.path, in: processes)
            let error = await WorktreeCleanup.remove(
                path: row.path, knownRepos: knownRepos, usedBy: users,
                deleteBranch: deletesBranch(row))
            if let error, let index = rows.firstIndex(where: { $0.path == row.path }) {
                rows[index].removing = false
                rows[index].error = error
                rows[index].remove = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) { rows.removeAll { $0.path == row.path } }
            }
        }
        WorktreeCleanup.removeEmptyRepoFolders()
        if rows.allSatisfy({ $0.error == nil }) { dismiss() }
    }

    /// Delete the archived session: its worktree to the Trash (re-checked
    /// first, as any removal is), then the session itself. A worktree that's
    /// already gone takes the session with it whatever git still says.
    func deleteArchived() async {
        guard let item = deletingItem else { return }
        await removeSelected()
        if !rows.contains(where: { $0.path == item.checkout })
            || !FileManager.default.fileExists(atPath: item.checkout) {
            manager.forgetArchived(item.id)
            dismiss()
        }
    }

    // MARK: -

    /// The repositories open sessions are in: where a registration whose
    /// folder is gone can be found.
    private static func repos(of manager: SessionManager) async -> [String] {
        let cwds = Set(manager.sessions.compactMap(\.cwd))
        var repos = Set<String>()
        for cwd in cwds {
            guard let root = await GitService.repoRoot(for: cwd) else { continue }
            repos.insert(await WorktreeCleanup.primaryCheckout(of: root) ?? root)
        }
        return Array(repos)
    }

}

/// The sheet. Minimal, and in today's macOS idiom (System Settings, Reminders):
/// a card per repository, one row per worktree, a round selection mark you can
/// click anywhere on the row to toggle, and the state on the right: quiet when
/// it's clean, a tinted pill when something keeps it. Everything longer (the
/// changed files, what's running there, the path) is the row's tooltip, and
/// Show in Finder its context menu.
struct WorktreeCleanupView: View {
    @Bindable var model: WorktreeCleanupModel

    /// Measured, so the sheet is exactly as tall as what's in it, up to a
    /// point, and only scrolls past that. A ScrollView has no height of its
    /// own to offer; guessing one either cut rows off or left a gap.
    @State private var contentHeight: CGFloat = 96

    private static let width: CGFloat = 480
    private static let maxContentHeight: CGFloat = 400
    private static let margin: CGFloat = 24

    /// Title, list, buttons, stacked: the list scrolls in a region of its
    /// own, the full width of the sheet with its scroller at the edge, and can
    /// never run under the title or the buttons. When it's long enough to
    /// scroll, a hairline marks each edge of that region, as in a sheet of
    /// Xcode's; a list that fits draws no lines at all.
    var body: some View {
        let scrolls = contentHeight > Self.maxContentHeight
        VStack(spacing: 0) {
            header
            if scrolls { Divider() }
            ScrollView {
                content
                    .padding(.horizontal, Self.margin)
                    .padding(.vertical, scrolls ? 12 : 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.maxContentHeight))
            if scrolls { Divider() }
            footer
        }
        .frame(width: Self.width)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.margin)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        if model.deletingItem != nil {
            return "Its worktree goes to the Trash, and the session with it. Anything with unsaved work stays."
        }
        return "Selected worktrees go to the Trash. Anything with unsaved work stays."
    }

    /// Repositories in name order, each with its worktrees by branch.
    private var groups: [(repo: String, rows: [WorktreeCleanupModel.Row])] {
        let byRepo = Dictionary(grouping: model.rows) { WorktreeRow.repoName(of: $0) }
        return byRepo.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { repo in
            (repo, byRepo[repo, default: []].sorted {
                WorktreeRow.name(of: $0).localizedStandardCompare(WorktreeRow.name(of: $1))
                    == .orderedAscending
            })
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for worktrees\u{2026}").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        } else if model.rows.isEmpty {
            Text("Nothing to clean up. Every worktree Wortel made is in use or already gone.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 96)
        } else {
            cards
        }
    }

    private static let groupHeaderHeight: CGFloat = 22
    private static let groupSpacing: CGFloat = 16

    private var showsHeaders: Bool { model.deletingItem == nil }

    private var cards: some View {
        VStack(alignment: .leading, spacing: Self.groupSpacing) {
            ForEach(groups, id: \.repo) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if showsHeaders {
                        // Grouped by folder from the start; named by the
                        // repository once a check says what it's called.
                        Text(group.rows.lazy.compactMap { $0.report?.repoName }.first ?? group.repo)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: Self.groupHeaderHeight)
                            .padding(.leading, 4)
                    }
                    VStack(spacing: 0) {
                        ForEach(group.rows) { row in
                            WorktreeRow(row: row, model: model)
                            if row.id != group.rows.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var footer: some View {
        footerControls
            .padding(.horizontal, Self.margin)
            .padding(.top, 16)
            .padding(.bottom, 20)
    }

    private var footerControls: some View {
        HStack(spacing: 10) {
            if model.isChecking && model.deletingItem == nil {
                // Where the branch switch will be: how far the checks are,
                // so a long list in a big repository is visibly moving.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking \(min(model.checkedCount + 1, model.rows.count)) of \(model.rows.count)\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if model.offersBranchDeletion {
                Toggle(isOn: $model.deleteBranches) {
                    Text("Also delete their branches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Only branches Wortel created, and only when every commit on them is also on another branch or a remote, or their changes are already in the default branch. Any other branch is kept.")
            }
            Spacer(minLength: 12)
            Button("Cancel") { model.dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            if model.deletingItem != nil {
                Button(model.isWorking ? "Deleting\u{2026}" : "Delete") {
                    Task { await model.deleteArchived() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.removableCount == 0 || model.isWorking)
            } else {
                Button(model.isWorking ? "Moving to Trash\u{2026}"
                       : model.removableCount == 0 ? "Move to Trash" : "Move \(model.removableCount) to Trash") {
                    Task { await model.removeSelected() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.removableCount == 0 || model.isWorking)
            }
        }
    }
}

private struct WorktreeRow: View {
    let row: WorktreeCleanupModel.Row
    let model: WorktreeCleanupModel
    @State private var hovering = false

    static let height: CGFloat = 38

    private var report: WorktreeReport? { row.report }
    private var isKept: Bool { report?.verdict == .blocked }
    private var selectable: Bool { report != nil && !isKept }

    var body: some View {
        HStack(spacing: 10) {
            mark
                .frame(width: 20)
            Text(Self.name(of: row))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isKept ? .secondary : .primary)
            Spacer(minLength: 12)
            status
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        // Inset and rounded, as a menu or sidebar highlights a row, rather
        // than a band across the card from edge to edge.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && selectable ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 5)
                .padding(.vertical, 3))
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        // Reachable without a pointer: Tab to it with Full Keyboard Access,
        // Space to tick, and VoiceOver's default action does the same.
        .focusable(selectable)
        .onKeyPress(.space) {
            toggle()
            return .handled
        }
        .help(tooltip)
        .contextMenu {
            if report?.isMissing != true {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectable ? (row.remove ? [.isButton, .isSelected] : .isButton) : [])
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        if selectable { model.setRemove(row.path, !row.remove) }
    }

    /// Round, as selection is in today's lists: filled when it goes, an empty
    /// ring when it could, a lock when it's kept.
    @ViewBuilder
    private var mark: some View {
        if report == nil || row.removing {
            ProgressView().controlSize(.small).scaleEffect(0.75)
        } else if isKept {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            Image(systemName: row.remove ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(row.remove ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    @ViewBuilder
    private var status: some View {
        if row.removing {
            Text("Moving to Trash\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if report == nil {
            // Said, not left blank: an empty right side read as "nothing
            // here" while git was still working out whether there was.
            Text("Checking\u{2026}")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if row.error != nil {
            pill("Couldn't remove", tint: .red)
        } else if let report {
            if let problem = problem(report) {
                pill(problem, tint: .orange)
            } else if report.mergedInto != nil, report.uniqueCommits != 0 {
                pill(model.deletesBranch(row) ? "Merged \u{00b7} branch too" : "Merged", tint: .green)
            } else {
                Text(quietStatus(report))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    /// What keeps it, in a word or three. The sentence is the tooltip.
    private func problem(_ report: WorktreeReport) -> String? {
        if report.isOrphanedFolder { return "Not a checkout" }
        if report.isPrimaryCheckout { return "Not a worktree" }
        if report.isLocked { return "Locked" }
        if !report.usedBy.isEmpty { return "In use" }
        if !report.changedFiles.isEmpty {
            let n = report.changedFiles.count
            return "\(n) change\(n == 1 ? "" : "s")"
        }
        if report.verdict == .blocked { return "Unsaved commits" }
        return nil
    }

    private func quietStatus(_ report: WorktreeReport) -> String {
        if report.isMissing { return "Folder already gone" }
        if report.verdict == .keepsCommits { return "Branch kept" }
        return model.deletesBranch(row) ? "Clean \u{00b7} branch too" : "Clean"
    }

    private var tooltip: String {
        if let error = row.error { return error + "\n" + row.path }
        guard let report else { return "Checking for changes\u{2026}\n" + row.path }
        return report.summary + "\n" + row.path
    }

    /// The branch, which is what a worktree is for; the folder when there isn't
    /// one (a detached HEAD) or it isn't known yet.
    static func name(of row: WorktreeCleanupModel.Row) -> String {
        row.report?.branch ?? row.branchHint ?? (row.path as NSString).lastPathComponent
    }

    /// The folder Wortel filed it under, which is the repository's name. Not
    /// the repository git reports: the grouping has to be right from the
    /// first frame, and a row moving to another card as its check landed was
    /// the list rearranging itself under the pointer.
    static func repoName(of row: WorktreeCleanupModel.Row) -> String {
        ((row.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }
}

enum WorktreeCleanupSheet {
    /// Show the sheet on `window`. It runs itself from there: the buttons act,
    /// and Cancel leaves everything as it was.
    @MainActor
    static func present(_ mode: WorktreeCleanupModel.Mode, manager: SessionManager, over window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        let model = WorktreeCleanupModel(mode: mode, manager: manager)
        let controller = NSHostingController(rootView: WorktreeCleanupView(model: model))
        // The sheet follows its content: it opens on "Looking for worktrees…"
        // and must grow when the rows arrive, rather than keep that first
        // size and squeeze them.
        controller.sizingOptions = [.preferredContentSize]
        let host = NSWindow(contentViewController: controller)
        model.dismiss = { [weak host] in
            guard let host else { return }
            host.sheetParent?.endSheet(host)
        }
        window.beginSheet(host)
    }
}
