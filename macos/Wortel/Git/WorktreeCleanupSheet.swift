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
    }

    let sessions: [SessionPlace]
    /// Processes not to count: the session being closed, whose shell and
    /// children are on their way out.
    let excludedPIDs: Set<pid_t>

    @MainActor
    init(manager: SessionManager, excluding closing: Session? = nil) {
        sessions = manager.sessions.filter { $0 !== closing }.map { session in
            SessionPlace(
                name: session.name,
                paths: [session.cwd, session.originCwd, session.gitCheckout].compactMap { $0 },
                shellPIDs: [session.shellPID].compactMap { $0 } + session.sideShells.map(\.pid))
        }
        var excluded = Set<pid_t>()
        if let closing {
            let roots = [closing.shellPID].compactMap { $0 } + closing.sideShells.map(\.pid)
            excluded = Self.tree(under: roots)
        }
        excludedPIDs = excluded
    }

    /// The pids under `roots`, roots included, as of now. Taken when the close
    /// is confirmed: once the shell is gone its children are reparented and no
    /// longer look like anyone's.
    nonisolated static func tree(under roots: [pid_t]) -> Set<pid_t> {
        guard !roots.isEmpty else { return [] }
        let table = ProcessTable.snapshot()
        var parentOf: [pid_t: pid_t] = [:]
        for entry in table { parentOf[entry.pid] = entry.ppid }
        var found = Set(roots)
        for entry in table where roots.contains(where: {
            ProcessTable.isDescendant(entry.pid, of: $0, parentOf: parentOf)
        }) {
            found.insert(entry.pid)
        }
        return found
    }

    /// Who is using `path`, for the report. Reads the process table, so call it
    /// off the main thread.
    nonisolated func users(of path: String) -> [String] {
        let inside: (String) -> Bool = { candidate in
            WorktreeCleanup.samePath(candidate, path)
                || WorktreeCleanup.canonical(candidate).hasPrefix(WorktreeCleanup.canonical(path) + "/")
        }
        var users: [String] = []
        var accounted = excludedPIDs
        for session in sessions where session.paths.contains(where: inside) {
            users.append("the session \u{201c}\(session.name)\u{201d}")
            // Its own processes are that session, already said.
            accounted.formUnion(Self.tree(under: session.shellPIDs))
        }

        let me = getuid()
        let app = getpid()
        var names: [String] = []
        // Not the app or its own children: the git it runs to inspect (and the
        // header's change counts) stands in these folders too, and would
        // otherwise read as "git, running there".
        for entry in ProcessTable.snapshot()
        where entry.uid == me && !accounted.contains(entry.pid) && entry.pid != app && entry.ppid != app {
            guard let cwd = ProcessTable.workingDirectory(of: entry.pid), inside(cwd) else { continue }
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
        var report: WorktreeReport?
        /// Move the folder to the Trash.
        var remove = false
        /// Delete the branch as well. Defaults on only when that loses nothing.
        var deleteBranch = false
        /// Why the last attempt kept it, when it did.
        var error: String?
        var id: String { path }
    }

    enum Mode {
        /// Every worktree Wortel made.
        case cleanUp
        /// One session's worktree, as part of closing it. `note` is what
        /// closing ends (a running agent), when anything.
        case closing(Session, note: String?)
    }

    let mode: Mode
    private(set) var rows: [Row] = []
    private(set) var isLoading = true
    private(set) var isWorking = false
    @ObservationIgnored private let manager: SessionManager
    @ObservationIgnored private var knownRepos: [String] = []
    @ObservationIgnored private var usage: WorktreeUsage
    @ObservationIgnored var dismiss: () -> Void = {}

    init(mode: Mode, manager: SessionManager) {
        self.mode = mode
        self.manager = manager
        if case .closing(let session, _) = mode {
            usage = WorktreeUsage(manager: manager, excluding: session)
        } else {
            usage = WorktreeUsage(manager: manager)
        }
    }

    var closingSession: Session? {
        if case .closing(let session, _) = mode { return session }
        return nil
    }

    var title: String {
        if let session = closingSession { return "Close \u{201c}\(session.name)\u{201d}?" }
        return "Clean Up Worktrees"
    }

    var removableCount: Int { rows.filter(\.remove).count }

    func load() async {
        knownRepos = await Self.repos(of: manager)
        let paths: [String]
        if let session = closingSession {
            paths = await Self.worktreePath(of: session).map { [$0] } ?? []
        } else {
            paths = await WorktreeCleanup.discover(knownRepos: knownRepos)
        }
        rows = paths.map { Row(path: $0) }
        isLoading = false
        let usage = self.usage
        for path in paths {
            let users = await Task.detached { usage.users(of: path) }.value
            let report = await WorktreeCleanup.inspect(path: path, knownRepos: knownRepos, usedBy: users)
            guard let index = rows.firstIndex(where: { $0.path == path }) else { continue }
            rows[index].report = report
            // The default is always the choice that loses nothing.
            rows[index].remove = report.verdict != .blocked
            rows[index].deleteBranch = report.verdict == .safe && report.ownsBranch
        }
        // A folder for a repo with nothing left in it is a trace too.
        if closingSession == nil { WorktreeCleanup.removeEmptyRepoFolders() }
    }

    func setRemove(_ path: String, _ on: Bool) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[index].remove = on
        if !on { rows[index].deleteBranch = false }
    }

    func setDeleteBranch(_ path: String, _ on: Bool) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[index].deleteBranch = on
        if on { rows[index].remove = true }
    }

    /// Remove what's ticked. Each is re-checked first (see
    /// `WorktreeCleanup.remove`); what's kept stays listed with the reason.
    func removeSelected() async {
        isWorking = true
        defer { isWorking = false }
        for row in rows where row.remove {
            let users = await Task.detached { [usage] in usage.users(of: row.path) }.value
            let error = await WorktreeCleanup.remove(
                path: row.path, knownRepos: knownRepos, usedBy: users,
                deleteBranch: row.deleteBranch,
                allowLosingCommits: row.deleteBranch && row.report?.verdict == .keepsCommits)
            if let error, let index = rows.firstIndex(where: { $0.path == row.path }) {
                rows[index].error = error
                rows[index].remove = false
            } else {
                rows.removeAll { $0.path == row.path }
            }
        }
        WorktreeCleanup.removeEmptyRepoFolders()
        if rows.allSatisfy({ $0.error == nil }) { dismiss() }
    }

    /// Close the session, then remove its worktree if that was chosen. The
    /// removal waits a moment for the session's processes to go, and re-checks:
    /// anything that turned up since the sheet was read keeps it, and says so.
    func closeSession() {
        guard let session = closingSession else { return }
        let row = rows.first
        // Taken now, while the shell's children still hang from it.
        let usage = WorktreeUsage(manager: manager, excluding: session)
        dismiss()
        manager.close(session)
        guard let row, row.remove else { return }
        let repos = knownRepos
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let users = await Task.detached { usage.users(of: row.path) }.value
            let error = await WorktreeCleanup.remove(
                path: row.path, knownRepos: repos, usedBy: users, deleteBranch: row.deleteBranch,
                allowLosingCommits: row.deleteBranch && row.report?.verdict == .keepsCommits)
            guard let error else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The worktree was kept"
            alert.informativeText = error
            alert.runModal()
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

    /// The worktree a session stands in: its checkout's root, when that's one
    /// Wortel made.
    private static func worktreePath(of session: Session) async -> String? {
        guard let cwd = session.cwd, let root = await GitService.repoRoot(for: cwd),
              WorktreeCleanup.isUnder(GitWorktree.root, root)
        else { return nil }
        return root
    }
}

struct WorktreeCleanupView: View {
    @Bindable var model: WorktreeCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.title)
                .font(.headline)
            if case .closing(_, let note?) = model.mode {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            footer
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for worktrees\u{2026}").foregroundStyle(.secondary)
            }
        } else if model.rows.isEmpty {
            Text(model.closingSession == nil
                 ? "No worktrees to clean up. Everything Wortel made is in use or already gone."
                 : "This session's folder isn't a worktree Wortel made.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        WorktreeRowView(row: row, model: model)
                        if row.id != model.rows.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: model.closingSession == nil ? 360 : nil)
            .fixedSize(horizontal: false, vertical: model.closingSession != nil)
        }
    }

    private var footer: some View {
        HStack {
            if model.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { model.dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.closingSession != nil {
                Button("Close Session") { model.closeSession() }
                    .keyboardShortcut(.defaultAction)
                    // Not until the worktree is read: closing first would
                    // decide its fate on a guess.
                    .disabled(model.isLoading || model.rows.contains { $0.report == nil })
            } else {
                Button(model.removableCount == 0 ? "Remove" : "Remove \(model.removableCount)") {
                    Task { await model.removeSelected() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.removableCount == 0 || model.isWorking)
            }
        }
    }
}

private struct WorktreeRowView: View {
    let row: WorktreeCleanupModel.Row
    let model: WorktreeCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.report?.branch ?? (row.path as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let repo = row.report?.repoName {
                        Text(repo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if row.report?.verdict == .blocked, !(row.report?.isMissing ?? false) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                    }
                    .controlSize(.small)
                }
            }
            if let report = row.report {
                details(report)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for changes\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = row.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func details(_ report: WorktreeReport) -> some View {
        Text(report.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if report.verdict != .blocked {
            Toggle(isOn: Binding(get: { row.remove }, set: { model.setRemove(row.path, $0) })) {
                Text(report.isMissing ? "Forget it" : "Move the folder to the Trash")
            }
            .toggleStyle(.checkbox)
            if report.ownsBranch, let branch = report.branch {
                Toggle(isOn: Binding(get: { row.deleteBranch },
                                     set: { model.setDeleteBranch(row.path, $0) })) {
                    switch report.uniqueCommits {
                    case 0?:
                        Text("Also delete branch \(branch)")
                    case let n?:
                        Text("Also delete branch \(branch) and its \(n) unsaved commit\(n == 1 ? "" : "s")")
                            .foregroundStyle(row.deleteBranch ? .red : .primary)
                    case nil:
                        Text("Also delete branch \(branch), whose commits may exist nowhere else")
                            .foregroundStyle(row.deleteBranch ? .red : .primary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

enum WorktreeCleanupSheet {
    /// Show the sheet on `window`. It runs itself from there: the buttons act,
    /// and Cancel leaves everything as it was.
    @MainActor
    static func present(_ mode: WorktreeCleanupModel.Mode, manager: SessionManager, over window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        let model = WorktreeCleanupModel(mode: mode, manager: manager)
        let host = NSWindow(contentViewController: NSHostingController(rootView: WorktreeCleanupView(model: model)))
        model.dismiss = { [weak host] in
            guard let host else { return }
            host.sheetParent?.endSheet(host)
        }
        window.beginSheet(host)
    }
}
