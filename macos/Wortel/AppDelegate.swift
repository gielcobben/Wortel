import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate,
    NSMenuItemValidation {
    /// Notification userInfo key carrying the session UUID string, so a tap can
    /// route back to the right session.
    private static let sessionKey = "sessionID"
    private(set) var runtime: GhosttyRuntime!
    private var manager: SessionManager!
    private var window: NSWindow!
    /// The one window the app has, for the things that need something to sheet
    /// onto and aren't held by the delegate — `newSessionOnBranch` is invoked
    /// from a menu and from a sidebar row, neither of which has a window in
    /// hand. Deliberately not `NSApp.keyWindow`: a preview window can be key,
    /// and a sheet about a session belongs on the window the session is in.
    /// Weak, so this doesn't outlive the window it names.
    static private(set) weak var mainWindow: NSWindow?
    /// The window's split: sessions, the main area, the side column. Held so
    /// the sidebar toggle and a click's area (`region(at:)`) reach it.
    private var splitController: MainSplitViewController!
    private var movability: WindowMovability?
    /// Drives the trailing source-control panel. Whether it's up follows the
    /// selected session (see GitPanelModel); new sessions start hidden.
    private let gitPanel = GitPanelModel()
    /// What every session is still running. Sampled slowly in the background,
    /// and read synchronously by the close sheet.
    private let processes = ProcessMonitor()
    /// The waiting sessions in the menu bar, while there are any.
    private var attentionItem: AttentionStatusItem?
    /// Drives the Files pane — the third view of the same column. Reads the repo
    /// the git panel has already resolved, so it costs no extra git work.
    private lazy var fileTree = FileTreeModel(git: gitPanel)
    /// The preview windows. Accessories to the main window — they close with it,
    /// so quitting stays what it has always been.
    private lazy var previewWindows = PreviewWindows(highlighter: DiffHighlighter.shared)
    /// Files previewed as tabs, the default way a file opens (see PreviewTabs);
    /// a window is one click away from any of them.
    private let previewTabs = PreviewTabs(highlighter: DiffHighlighter.shared)
    /// The `wortel` command's way in. Started once the session manager exists,
    /// since every command it serves is about a session.
    private var cli: WortelCLIService?
    /// Sparkle auto-updater. Constructed here (rather than lazily) so scheduled
    /// background update checks start at launch; the "Check for Updates…" menu
    /// item drives manual checks through it.
    private let updater = Updater.shared
    /// The Settings window while it is open (`showSettings`).
    private var settingsWindow: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu must exist before launch so key equivalents resolve immediately.
        NSApp.mainMenu = MainMenu.build()
        MainMenu.browserInFront = { [weak self] in self?.frontBrowser() != nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else {
            fatalError("failed to initialize libghostty")
        }
        self.runtime = runtime
        #if DEBUG
        AppearanceTestHook.install()
        // These two drive the app: they resize its window, switch its
        // sessions and, for one check, close them all. Only ever a
        // throwaway copy, which is one with a data folder of its own; a
        // Debug build is also what runs every day.
        if DataDirectory.custom != nil { ResizeBench.install() }
        #endif
        // Housekeeping, well off the launch path.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            DropPasteboard.sweepOldImages()
        }

        let manager = SessionManager(runtime: runtime)
        self.manager = manager
        #if DEBUG
        if DataDirectory.custom != nil { SwitchProbe.install(manager: manager, git: gitPanel) }
        #endif

        // AppKit window hosting a SwiftUI NavigationSplitView (the Opslan
        // layout). fullSizeContentView so the sidebar runs to the top; SwiftUI
        // drives the title/toolbar/floating sidebar itself.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // NSWindow's own initializers leave this `true` — only NSWindowController
        // turns it off, and this window has none. Under ARC that is an unbalanced
        // release: `close()` frees the window while the strong `window` property
        // below still points at it, and the next thing to read that property
        // retains freed memory. It crashed exactly there: closing the last session
        // changes `manager.selected`, which schedules the title observer's
        // `Task { @MainActor }`, and `onAllClosed` closes the window before that
        // task gets its turn — so `applyWindowTitle` segfaulted in `objc_retain`.
        // `.terminateLater` (telemetry drain) keeps the process alive long enough
        // to make it likely rather than rare.
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The titlebar is Wortel's own (see TitleBars.swift): every pane draws
        // its row of it, and the system draws nothing there but the traffic
        // lights. Transparent, so clicks reach the rows under it; no title, the
        // terminal's row shows the session's name itself; no separator, each row
        // draws its own hairline.
        //
        // The toolbar stays, empty, for the one thing only it can do: make the
        // titlebar tall enough for a row of controls and centre the traffic
        // lights in it. Compact is 40pt, next to the ChatGPT app's 42.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        // The window server's own titlebar dragging is off, and the rows start
        // window moves themselves from their empty space (`performWindowDrag`,
        // ChromeBarView). Left on, it moved the window from *anywhere* in the
        // titlebar, tabs included, whatever the view under the pointer said:
        // a tab drag carried the whole window along under the cursor, so the
        // tab never moved relative to anything. This is how Electron apps, the
        // ChatGPT app among them, give their titlebars draggable tabs. Moves
        // started this way still snap, tile and cross Spaces like any other.
        // On only for the moments tiling needs it (WindowMovability, installed
        // once the content is in): a window that's never movable has its whole
        // tiling set greyed out in the Window menu, fn-⌃C and the rest with it.
        window.isMovable = false
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "wortel.main")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // The rows are as tall as the titlebar the system made, measured rather
        // than assumed: it's the system's number and differs across releases.
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        if titlebarHeight > 20 { Chrome.titlebarHeight = titlebarHeight }
        let titleBars = TitleBarController(manager: manager, git: gitPanel, processes: processes)
        self.titleBars = titleBars
        let split = MainSplitViewController(
            runtime: runtime, manager: manager, git: gitPanel, files: fileTree,
            titleBars: titleBars, previewTabs: previewTabs)
        self.splitController = split
        manager.onSwitch = { [weak split] session in split?.show(session) }
        // A file dragged out of a list onto a tab row or an area opens there,
        // through the same opener as a double-click, so it shows the same diff.
        split.openDroppedFiles = { [weak self] urls, region, index in
            for (offset, url) in urls.enumerated() {
                self?.openPreview(url, placement: .dropped(region, index: index == .max ? .max : index + offset))
            }
        }
        window.contentViewController = BackdropController(child: split, overlay: titleBars.sidebarControls)
        movability = WindowMovability(window: window)
        titleBars.start()
        window.setFrameAutosaveName("main")
        if window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        self.window = window
        Self.mainWindow = window

        // Closing the last session leaves the window up on an empty page with
        // Open Folder on it, rather than quitting: the last ⇧⌘W was usually
        // the end of a task, not of the day. ⌘W on that page closes the
        // window, and the app with it.
        manager.onAllClosed = { [weak self] in
            self?.gitPanel.focus(session: nil)
            self?.fileTree.focus(session: nil)
        }
        // Previews are accessories: without this, closing the last session would
        // leave a preview window standing, which both keeps the app alive (the
        // last window hasn't closed) and leaves a terminal with no terminal in it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.previewWindows.closeAll()
                // The same goes for Settings: left open, it would be the last
                // window, and the app would stay up with nothing in it.
                self?.settingsWindow?.close()
            }
        }
        manager.confirmClose = { [weak self] session, completion in
            self?.confirmClose(session, completion: completion)
        }
        manager.confirmCloseSessions = { [weak self] batch, running, completion in
            self?.confirmClose(batch, running: running, completion: completion)
        }
        manager.onArchiveProblem = { [weak self] title, detail in
            guard let window = self?.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.beginSheetModal(for: window)
        }
        // A scan from the last second, not the background snapshot: closing
        // silently stops what the session runs, and a server started in the
        // last ten seconds is exactly the one a stale snapshot would miss. The
        // sheet and the stop share this scan rather than taking their own.
        manager.hasBackgroundWork = { [weak self] session in
            !(self?.processes.recentScan().workToStop(for: session.id).isEmpty ?? true)
        }
        manager.stopSessionWork = { [weak self] session in
            self?.processes.stopWork(of: session.id)
        }
        processes.roots = { [weak manager] in manager?.processRoots ?? [] }
        processes.projectRoots = { [weak manager] in manager?.projectRoots ?? [] }
        processes.startSampling()
        manager.onNeedsAttention = { [weak self] session, kind, title, body, alert in
            self?.postAttentionNotification(session, kind: kind, title: title, body: body, alert: alert)
        }
        // Picking a row there is a click on its notification: that session,
        // with Wortel in front.
        let attentionItem = AttentionStatusItem(
            manager: manager,
            open: { [weak self] id in
                self?.manager.select(id: id)
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            },
            showApp: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            })
        self.attentionItem = attentionItem
        manager.onAttentionChanged = { [weak attentionItem] in attentionItem?.refresh() }
        watchCommandHold()
        // A command finished in the selected session → refresh the git panel
        // (it debounces and no-ops while hidden).
        manager.onCommandFinished = { [weak self] session in
            guard let self, session.id == self.manager.selectedID else { return }
            self.gitPanel.refreshCurrent()
        }
        // Everything that opens a file — a ⌘-clicked path in the terminal, a
        // double-clicked row in the tree, a Changes row, a file in a commit —
        // goes through one opener, so which diff a window shows is decided in
        // one place rather than four.
        manager.onOpenTerminalLink = { [weak self] target in
            self?.openTerminalLink(target)
        }
        // A ⌘-clicked localhost link goes where a server picked from the
        // running-jobs popover goes: a tab beside the terminal (one already
        // on that server comes forward), or the browser when Settings says
        // servers go there, or when there is no session to hold a tab.
        manager.onOpenLocalServer = { [weak self] url in
            if let self, !AppSettings.shared.opensServersInDefaultBrowser, self.gitPanel.session != nil {
                self.gitPanel.showInBrowser(url, elsewhere: Self.optionClicked)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        manager.onKeeperLost = { [weak self] loss in
            self?.reportKeeperLoss(loss)
        }
        fileTree.onOpenPreview = { [weak self] url in
            self?.openPreview(url)
        }
        gitPanel.onOpenPreview = { [weak self] url, diff, hasChanges in
            self?.presentPreview(url, diff: diff, hasChanges: hasChanges)
        }
        previewTabs.onOpenFile = { [weak self] url in
            self?.openPreview(url)
        }
        // A tab becoming a window: the window opens and the tab goes.
        previewTabs.onOpenInWindow = { [weak self] url, diff, hasChanges, mode, topLeft in
            guard let self else { return }
            self.previewWindows.open(url, diff: diff, hasChanges: hasChanges, mode: mode, at: topLeft)
            self.gitPanel.close(.file(url.path))
        }
        // Browsers keep where they are on their session, so a relaunch or a
        // reopen goes back there.
        BrowserTabs.shared.address = { [weak self] id in
            self?.manager.sessions.lazy.compactMap { $0.browserAddresses[id] }.first
                .flatMap(URL.init(string:))
        }
        BrowserTabs.shared.onNavigate = { [weak self] id, url in
            guard let self, url.scheme != "about",
                  let session = self.manager.sessions.first(where: {
                      $0.workspace.region(of: .browser(id)) != nil
                  }),
                  session.browserAddresses[id] != url.absoluteString else { return }
            session.browserAddresses[id] = url.absoluteString
            self.manager.sessionStateChanged()
        }
        // What a browser's address field suggests: every server on this Mac,
        // the selected session's first, the others by their session's name.
        BrowserTabs.shared.servers = { [weak self] in
            guard let self else { return [] }
            let selected = self.manager.selectedID
            let snapshot = self.processes.snapshot
            var seen = Set<URL>()
            return (snapshot.jobs + snapshot.orphans)
                .filter { $0.localURL != nil }
                .sorted { ($0.sessionID == selected ? 0 : 1) < ($1.sessionID == selected ? 0 : 1) }
                .compactMap { job in
                    guard let url = job.localURL, seen.insert(url).inserted else { return nil }
                    let session = job.sessionID == selected ? nil
                        : self.manager.sessions.first { $0.id == job.sessionID }.map { SessionName.leaf(of: $0.name) }
                    return BrowserServer(url: url, label: job.label, session: session)
                }
        }
        gitPanel.onTabClosed = { [weak self] tab in
            if let path = tab.filePath { self?.releaseFile(path) }
            if let id = tab.browserID { BrowserTabs.shared.forget(id) }
        }
        // A closed session's pages and documents go with it: a web view keeps
        // running its scripts and its dev server's socket, and a document
        // keeps watching its file, for as long as anything holds them.
        manager.onSessionClosed = { [weak self] session in
            let workspace = session.workspace
            let tabs = workspace.main + workspace.side + workspace.bottom + workspace.closed.map(\.tab)
            for tab in tabs {
                if let id = tab.browserID { BrowserTabs.shared.forget(id) }
                if let path = tab.filePath { self?.releaseFile(path) }
            }
        }
        // A link in a rendered README is a fifth way to open a file, and it goes
        // through the same opener as the other four.
        // A preview window dragged back onto a tab row becomes a tab there,
        // with the window's diff and on its view: the way out keeps both, so
        // the way back does too.
        previewWindows.onDock = { [weak self] phase, document, window, point in
            guard let self,
                  let landing = self.splitController.dockWindowDrag(
                      phase, url: document.url, dragged: window, at: point) else { return false }
            if phase == .ended {
                self.presentPreview(document.requestedURL, diff: document.diffSource,
                                    mode: document.mode,
                                    placement: .dropped(landing.region, index: landing.index))
            }
            return true
        }
        previewWindows.onOpenFile = { [weak self] url in
            self?.openPreview(url)
        }
        manager.onAttentionCleared = { session in
            // The user answered (or the session closed) — pull the banner out
            // of Notification Center instead of leaving it stale.
            let center = UNUserNotificationCenter.current()
            let id = session.id.uuidString
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
        }
        manager.onReminderChanged = { session, date in
            Self.scheduleReminderFallback(for: session, at: date)
        }
        manager.onReminderDue = { session in
            Self.postReminder(for: session)
        }

        // Occlusion drives "can the user actually see the window": an active
        // app with a miniaturized or fully covered window should still get
        // attention signals for its selected session.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)

        // Native "a session needs you" notifications. The signal is
        // program-authored (e.g. Claude Code emits OSC 777 on a permission/idle
        // prompt because libghostty sets TERM_PROGRAM=ghostty) — we just relay
        // it. Ask once; if the user declines, the sidebar dot + Dock badge still
        // work.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // The grant is remembered because the turn-end chime is played by us,
        // not by Notification Center (see playTurnDoneChime): someone who
        // declined notifications should not be chimed at anyway.
        // `.badge` is here for the **Dock badge**, which is drawn by us rather
        // than by Notification Center — `NSApp.dockTile.badgeLabel`. Once an app
        // registers with `UNUserNotificationCenter`, macOS gates that badge on
        // the same per-app "Badges" permission, so an app that asks only for
        // alerts and sounds can set `badgeLabel` all day and the Dock will
        // ignore it. Which is exactly what it was doing.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                Self.notificationsAuthorized = granted
                Permissions.shared.refresh()
            }
        }

        // Panel visibility and the chosen pane are session state, so a toggle has
        // to reach sessions.json.
        gitPanel.onStateChanged = { [weak manager] in manager?.sessionStateChanged() }
        // Every tab brought forward is a stop on Back and Forward's trail.
        gitPanel.onTabBroughtForward = { [weak manager] tab, session in
            manager?.noteTabBroughtForward(tab, in: session)
        }
        // Bring Here: an archived session's worktree is in use too, waiting
        // for it to come back.
        gitPanel.worktreeUsage = { [weak manager] in
            manager.map { WorktreeUsage(manager: $0, countingArchived: true) }
        }
        // The git panel's worktree list is the manager's: one cached `git
        // worktree list` per repository, which ⌘P already keeps
        // (`worktreeListings`), rather than a read of its own on every
        // session switch.
        gitPanel.worktreeListing = { [weak manager] home in manager?.worktreeListings[home] }
        // What the panel calls a checkout: the session in it, live or
        // archived (`CheckoutPlace`).
        gitPanel.placeName = { [weak manager] path in
            guard let manager else { return nil }
            return CheckoutPlace.sessionName(
                at: GitWorktree.realPath(path),
                live: manager.sessions.map {
                    CheckoutPlace.Live(home: $0.homeCheckout?.root, visiting: $0.linkedCheckout?.root,
                                       name: $0.leafName)
                },
                archived: manager.archived.map { CheckoutPlace.Archived(checkout: $0.checkout, name: $0.leafName) })
        }
        // The side column's tabs: a side shell that exits takes its tab with it,
        // closing one that still runs something asks first, and the tab that had
        // the keyboard hands it back to the session's own terminal.
        manager.onSideTerminalExited = { [weak self] session, id in
            self?.gitPanel.close(.terminal(id), in: session)
        }
        gitPanel.confirmCloseTerminal = { [weak self] count, proceed in
            self?.confirmCloseSideTerminal(count: count, proceed)
        }
        SurfaceView.onKeyboardActivity = { [weak self] surface in
            self?.noteKeyboardActivity(in: surface)
        }
        // A click in an area puts you in it, whatever it lands on: a web page,
        // a pane's list or the file tree never take part in the terminals'
        // typing reports, and without this ⌘W after clicking into a browser in
        // the column went to wherever you'd last typed.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  let region = self.splitController.region(at: event.locationInWindow) else { return event }
            if self.gitPanel.lastRegion != region { self.gitPanel.lastRegion = region }
            return event
        }
        gitPanel.onAreaFocused = { [weak self] region in
            // A turn later: an area the command brought forward has its frame then.
            DispatchQueue.main.async { self?.splitController.blink(region) }
        }
        gitPanel.onClearKeyboard = { [weak self] in
            guard let window = self?.window, window.firstResponder is SurfaceView else { return }
            window.makeFirstResponder(nil)
        }
        manager.onReturnKeyboard = { [weak self] in
            guard let self, let window = self.window, let session = self.manager.selected else { return }
            if session.workspace.showsSessionTerminal {
                // Its own terminal is in front, wherever its row is: that,
                // once it is there to take it. One still waking is given the
                // keyboard as it is shown (`TerminalHostViewController`), and
                // the area it is in is noted then (`noteKeyboardActivity`).
                guard let view = session.surfaceView, view.window === window,
                      !view.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(view)
            } else {
                // A file, a page or a pane in front of it: what is in front
                // of the main area, which is then where you are, so ⌘W and
                // the rest act there.
                if self.gitPanel.lastRegion != .main { self.gitPanel.lastRegion = .main }
                self.gitPanel.focusFront(of: .main)
            }
        }
        gitPanel.onFocusMainTerminal = { [weak self] in
            // Not while a tab in the main area's row covers the terminal.
            guard let self, self.gitPanel.activeMainTab == nil,
                  let view = self.manager.selected?.surfaceView,
                  view.window === self.window, !view.isHiddenOrHasHiddenAncestor else { return }
            self.window?.makeFirstResponder(view)
        }

        // **Before any surface exists.** `GhosttyRuntime.keeper` is a lazy
        // static, and touching it for the first time from inside surface
        // creation means its initialiser runs while SwiftUI is mid-update — so
        // anything in it that lets the run loop turn can re-enter surface
        // creation and deadlock on its own `dispatch_once`. Doing it here makes
        // that impossible rather than merely unlikely.
        _ = GhosttyRuntime.keeper

        manager.restore()
        // Folders handed over before the sessions were back (a folder dropped
        // on the Dock icon to launch the app).
        pendingFolders.forEach { manager.openFolder($0, starting: .preferred) }
        pendingFolders = []
        // Point the panel at the restored selection: it's what raises the panel
        // if that session had it up, and it seeds the cwd so the first toggle
        // resolves the right repo (no git work runs while it's hidden).
        gitPanel.focus(session: manager.selected)
        fileTree.focus(session: manager.selected)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The window has to exist before the chord that raises it can be
        // claimed, and nothing after this point is something the hot key needs.
        GlobalHotkey.shared.start { [weak self] in self?.toggleAppVisibility(nil) }

        // Last, because everything it can be asked to do has to exist first.
        let cli = WortelCLIService(
            manager: manager,
            openPreview: { [weak self] url in self?.openPreview(url) },
            orderFront: { [weak self] in self?.window?.makeKeyAndOrderFront(nil) })
        cli.start()
        self.cli = cli

        observeWindowTitle()

        // Counted here and reported below, because both of these are consumed
        // as the app comes up: a pending resume is cleared the moment its
        // shell is ready to take it, so reading it a runloop turn later would
        // report a number that shrinks with how fast the machine is.
        let restored = manager.sessions.count
        let resumed = manager.sessions.filter { $0.pendingResumeInput != nil }.count

        // Deliberately after the first frame, and deliberately last. Cold
        // launch is a benchmarked number (bench/measure.sh) and this feature is
        // not allowed to move it, so nothing about reporting runs until the
        // window is up: the client is not built, no preference is read and no
        // request is made. Same one-runloop-turn trick as warmRemainingSurfaces.
        DispatchQueue.main.async {
            // Read now, before the capture below: sending is what makes the id.
            let first = TelemetrySettings.isEnabled && !TelemetrySettings.hasInstallID
            // Only after a run that never quit, and only when it would be
            // reported: otherwise nothing reads the crash reports at all.
            let uncleanSince = TelemetrySettings.isEnabled ? ExitMarker.uncleanRunStartedAt : nil
            // Asked of macOS directly rather than read off `Permissions`, which
            // may not have heard back yet this early and would say "unknown"
            // on every launch. The answer arrives off the main thread, which is
            // also where the crash report, a few hundred KB of JSON, is read.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let crash = uncleanSince.flatMap { CrashReport.latest(after: $0) }
                let previousExit = ExitMarker.previousExit(
                    firstLaunch: first, markerFound: ExitMarker.lastRunEndedUncleanly,
                    crashReported: crash != nil)
                if let crash { Telemetry.capture(crash.event) }
                let notifications: NotificationState
                switch settings.authorizationStatus {
                case .notDetermined: notifications = .notAsked
                case .denied: notifications = .denied
                case .authorized, .provisional, .ephemeral:
                    // The same rule as `Permissions.refresh`: allowed with
                    // every way of showing one turned off is not allowed.
                    notifications = settings.alertSetting == .enabled
                        || settings.notificationCenterSetting == .enabled ? .granted : .denied
                @unknown default: notifications = .unknown
                }
                Telemetry.capture(.appLaunched(sessions: CountBucket(restored),
                                               agentsResumed: CountBucket(resumed),
                                               first: first, previousExit: previousExit,
                                               notifications: notifications))
            }
            // Hangs off the ⓘ in the sidebar, which is also where it lives
            // afterwards: shown once, reachable forever.
            TelemetryNotice.shared.presentFirstRunIfNeeded()
        }
    }

    /// When this launch started, for the uptime bucket on quit.
    private let launchedAt = Date()

    /// The window's titlebar rows and what keeps them current.
    private var titleBars: TitleBarController?

    /// The window title used to come from SwiftUI's .navigationTitle, which only
    /// exists inside a NavigationSplitView — gone with the AppKit shell, so drive
    /// NSWindow's own title/subtitle instead. Unified toolbar style puts them in
    /// the content section, i.e. starting at the sidebar's trailing edge.
    /// @Observable tracking is one-shot, so the observer re-arms after each change.
    private func observeWindowTitle() {
        withObservationTracking {
            _ = manager.selected?.name
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyWindowTitle()
                self.observeWindowTitle()
            }
        }
        applyWindowTitle()
    }

    /// The session's name and nothing else. The path used to sit under it as a
    /// subtitle, which changed on every `cd` and made the titlebar the one piece
    /// of chrome that moved while you typed; the prompt already says where you
    /// are.
    private func applyWindowTitle() {
        window?.title = manager.selected?.name ?? "Wortel"
    }

    // MARK: - Show/hide from anywhere (⌃⌥⌘., see GlobalHotkey)

    /// One key, two meanings, and which one you get is decided by whether you
    /// can already see the app: frontmost with a window up means put it away,
    /// and everything else means bring it back.
    ///
    /// "Everything else" is doing the work here. Hidden, buried under another
    /// app, and miniaturized in the Dock are three unrelated AppKit states, but
    /// someone pressing this key means the same thing by all three, so all three
    /// are undone on the way up. `NSApp.hide` is what makes the return trip
    /// cheap: AppKit remembers what was on screen when it hid, so `unhide`
    /// restores the preview windows that were open beside the terminal without
    /// this having to track them.
    ///
    /// It runs from the menu item too, where only the hide half is ever
    /// reachable — you cannot pick a menu from an app you are not in.
    @objc func toggleAppVisibility(_ sender: Any?) {
        Telemetry.capture(.globalHotkeyUsed)

        let onScreen = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        if NSApp.isActive, !NSApp.isHidden, onScreen {
            NSApp.hide(nil)
            return
        }

        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // The one place in the app that activates over whatever you were doing.
        // The `wortel` command deliberately never does this (a hook firing
        // behind your back must not take your keyboard); a chord you pressed
        // yourself is the opposite case.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Focus tracking (drives "actively viewing" → no attention shout)

    func applicationDidBecomeActive(_ notification: Notification) {
        manager?.appDidBecomeActive()
        processes.setInBackground(false)
        // Whatever happened to the work tree while we were away — a branch
        // switched in another window, a build run from another terminal — the
        // file tree's watchers may not have been able to see it. Coming back is
        // the natural moment to re-read what's open. No-ops unless the tree is
        // the pane on screen.
        fileTree.resync()
    }

    func applicationDidResignActive(_ notification: Notification) {
        manager?.appDidResignActive()
        processes.setInBackground(true)
        commandHold?.cancel()
        manager?.showsShortcutHints = false
    }

    /// ⌘ held alone for a moment shows each row's ⌘1…⌘9 (Supacode and Conductor
    /// do the same). A moment, not at once: ⌘ goes down for every shortcut, and
    /// hints flashing at each ⌘C would be noise. Any key, or any other
    /// modifier, puts them away. A local monitor: only Wortel's own events,
    /// which needs no permission.
    private var commandHold: DispatchWorkItem?

    private func watchCommandHold() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.commandHoldChanged(event)
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.sidebarSelectionKey(event) else { return event }
            return nil
        }
    }

    /// The sidebar's selection of several rows ends at Esc, or as soon as you
    /// type in the window. Here rather than in the sidebar because the sidebar
    /// never holds the keyboard: the terminal does, and Esc would otherwise go
    /// to it.
    ///
    /// Esc is taken only while there *is* a selection of several, so it costs
    /// the terminal nothing the rest of the time. And typing ends the
    /// selection too (passed on, not taken), which is what keeps that one
    /// case honest: once you're back at work in the terminal there's no
    /// selection left for an Esc meant for vim, or for an agent's interrupt,
    /// to be swallowed by. Returns whether to take the event.
    private func sidebarSelectionKey(_ event: NSEvent) -> Bool {
        guard manager.sidebarSelection.isMultiple, event.window === window,
              window?.attachedSheet == nil, manager.editingID == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌘ shortcuts (Pin, the palette…) are commands, not typing.
        guard !modifiers.contains(.command) else { return false }
        manager.collapseSidebarSelection()
        return event.keyCode == 53 && modifiers.isEmpty
    }

    private func commandHoldChanged(_ event: NSEvent) {
        commandHold?.cancel()
        commandHold = nil
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged, modifiers == .command {
            let show = DispatchWorkItem { [weak self] in self?.manager.showsShortcutHints = true }
            commandHold = show
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: show)
        } else if manager.showsShortcutHints {
            manager.showsShortcutHints = false
        }
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard let window else { return }
        manager?.windowVisibilityChanged(window.occlusionState.contains(.visible))
    }

    // MARK: - Attention notifications

    /// Post (or replace) the "needs you" notification for a session. Uses the
    /// session id as the request identifier so a chatty program updates one
    /// notification instead of stacking many. Informational "finished" pings
    /// arrive silently; blocked prompts and failures make a sound.
    private func postAttentionNotification(_ session: Session, kind: AttentionKind, title: String, body: String, alert: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Which session this is about, always. When the program authored the
        // notification the title is its own ("Codex", "Waiting for Approval")
        // and named no session at all, which leaves the banner indistinguishable
        // from one raised by any other session running the same agent.
        if title != session.name { content.subtitle = session.name }
        // Sound only on an escalation the manager flagged, so a program that
        // re-fires the same kind updates the banner text without re-dinging.
        //
        // Only the standard alert goes through UNNotificationSound: on macOS
        // that API reliably plays exactly one sound, `.default`. Naming a system
        // sound is not a documented path and reportedly just plays nothing —
        // and a chime that is silently silent is worse than no chime, since it
        // looks shipped. So the quieter turn-end tier is played directly
        // through NSSound, which does read /System/Library/Sounds.
        // Trade-off: an NSSound isn't routed by Notification Center, so it is
        // heard even when a Focus would have suppressed the banner.
        content.sound = (alert && kind.chime == .alert) ? .default : nil
        if alert, kind.chime == .soft { Self.playTurnDoneChime() }
        content.userInfo = [Self.sessionKey: session.id.uuidString]
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil)
        // What Notification Center made of it, said in the same log as the
        // decision to raise it. Without this the last step is invisible: an
        // ad-hoc build is told `granted` and posts without an error, and
        // nothing is shown, so "no banner" could be the detection or the
        // system and nothing told them apart.
        let id = session.id.uuidString
        let sound = content.sound != nil ? "alert" : (alert && kind.chime == .soft ? "chime" : "none")
        UNUserNotificationCenter.current().add(request) { error in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                AgentStatusLog.log.debug("""
                    banner \(error == nil ? "handed to Notification Center" : "refused", privacy: .public) \
                    sound=\(sound, privacy: .public) \
                    allowed=\(settings.authorizationStatus == .authorized, privacy: .public) \
                    banners=\(settings.alertSetting == .enabled, privacy: .public) \
                    \(error.map { "error=\($0.localizedDescription)" } ?? "", privacy: .public) \
                    id=\(id, privacy: .public)
                    """)
            }
        }
    }

    // MARK: - Reminders

    /// A session's reminder banner, one per session, apart from its attention
    /// banner: answering what an agent asked must not take back a reminder.
    private static func reminderID(_ session: Session) -> String {
        "reminder." + session.id.uuidString
    }

    nonisolated private static func reminderContent(sessionID: UUID, name: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = name
        // You asked for it, at a time you chose: it rings like a calendar's.
        content.sound = .default
        content.userInfo = [sessionKey: sessionID.uuidString]
        return content
    }

    /// The banner for a reminder, left with Notification Center so it comes
    /// even with Wortel quit. Set a minute late on purpose
    /// (`SessionManager.reminderFallbackDelay`): a Wortel that is
    /// running takes it back on time and posts its own (`postReminder`),
    /// with the session's name as it is by then. nil takes it back, shown or
    /// not.
    private static func scheduleReminderFallback(for session: Session, at date: Date?) {
        let center = UNUserNotificationCenter.current()
        let id = reminderID(session)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        guard let date else { return }
        // With the time zone: the trigger is for that moment, not for that
        // time on the clock wherever the Mac has travelled to since.
        let when = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .timeZone],
            from: date.addingTimeInterval(SessionManager.reminderFallbackDelay))
        center.add(UNNotificationRequest(
            identifier: id, content: reminderContent(sessionID: session.id, name: session.name),
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
    }

    /// A reminder went off for a session nobody is looking at. Unless the
    /// late banner above already showed (the Mac slept through both), it is
    /// taken back and this one posted in its place, so there is one banner.
    private static func postReminder(for session: Session) {
        let center = UNUserNotificationCenter.current()
        let id = reminderID(session)
        let sessionID = session.id
        let name = session.name
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.getDeliveredNotifications { delivered in
            guard !delivered.contains(where: { $0.request.identifier == id }) else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: id, content: reminderContent(sessionID: sessionID, name: name), trigger: nil))
        }
    }

    /// Whether the user allowed notifications, remembered from the launch
    /// prompt. Only gates the chime we play ourselves — everything Notification
    /// Center delivers is already gated by the system.
    private static var notificationsAuthorized = false

    /// Held for the app's lifetime: an NSSound stops if its object goes away
    /// mid-play, and this one is re-triggered rather than rebuilt each time.
    private static let turnDoneChime = NSSound(named: "Tink")

    /// "Your move" — quieter and clearly distinct from the alert ding, so the
    /// two are tellable apart from the next room. Restarted rather than
    /// overlapped when two agents finish at once.
    private static func playTurnDoneChime() {
        guard notificationsAuthorized, let chime = turnDoneChime else { return }
        chime.stop()
        chime.play()
    }

    /// Foreground delivery: still show the banner (the user is in another
    /// session, or away from the keyboard) — we only get here when the session
    /// isn't the actively-viewed one.
    // UNUserNotificationCenterDelegate requirements are nonisolated; marking the
    // implementations `nonisolated` keeps this @MainActor class's conformance from
    // crossing actor boundaries (a Swift 6 data-race error). Both callbacks are
    // delivered on the main thread, so the one that touches main-actor state hops
    // in synchronously via assumeIsolated.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the notification jumps to that session and brings Wortel front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            // "Wortel … is ready": come forward, where the update icon is.
            // Restarting is still yours to click.
            if response.notification.request.identifier == Updater.notificationID {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            if let idString = response.notification.request.content.userInfo[Self.sessionKey] as? String,
               let id = UUID(uuidString: idString) {
                manager?.select(id: id)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        completionHandler()
    }

    /// A folder dropped on the Dock icon, or opened with Wortel from Finder:
    /// what ⌘O does with it. Files aren't Wortel's to open from outside.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.path)
        guard !folders.isEmpty else { return }
        // At launch this can come before the sessions are restored.
        guard let manager, manager.hasRestored else { return pendingFolders += folders }
        folders.forEach { manager.openFolder($0, starting: .preferred) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private var pendingFolders: [String] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Give the last events a moment to leave, without blocking the main thread
    /// to do it.
    ///
    /// State goes to disk **first**, before anything is allowed to wait, so a
    /// quit that is killed mid-drain still has the session list saved. Both
    /// calls are idempotent and `applicationWillTerminate` runs them again for
    /// the termination paths that never reach here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        manager?.saveNow()
        // The banners left with Notification Center are for now: under each
        // session's name as it is on the way out.
        manager?.scheduleReminderFallbacks()
        // The sessions outlive us; what their terminals were told has to as
        // well, or the next launch pastes into an agent without brackets.
        TerminalModeRecorder.shared.save()
        cli?.stop()
        Telemetry.capture(
            .appQuit(uptime: DurationBucket(seconds: Date().timeIntervalSince(launchedAt))))
        guard Telemetry.hasWorkBeforeQuit else { return .terminateNow }
        Telemetry.drainBeforeQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.saveNow()
        TerminalModeRecorder.shared.save()
        // The socket's name is a file, and it outlives the process that made
        // it. The server recovers from a stale one on the next launch, but only
        // by proving it's stale — cheaper and less alarming to tidy up.
        cli?.stop()
        // Nothing we started outlives us: a fetch hung on a dead network would.
        GitService.terminateAll()
        // Last: this run quit properly. See ExitMarker.
        if ExitMarker.applies { ExitMarker.disarm() }
    }

    // MARK: - A lost keeper

    /// Say that the terminals were lost and what came back, once, when it
    /// happens. The fix-up already ran by now (see
    /// `SessionManager.keeperDidExit`); this is so it is never silent again.
    /// Silent was the 2026-10-08 incident: every agent gone, a sidebar that
    /// still looked fine, and seven minutes before anyone found out.
    private func reportKeeperLoss(_ loss: SessionManager.KeeperLoss) {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let time = DateFormatter.localizedString(from: loss.at, dateStyle: .none, timeStyle: .medium)
        var lines = ["At \(time), something outside Wortel ended the process that keeps your terminals running."]
        if loss.restarted > 0 || loss.resumed > 0 {
            var line = "Wortel started new shells in \(count(loss.restarted, "terminal", "terminals"))"
            if loss.resumed > 0 {
                line += " and resumed " + (loss.resumed == 1
                    ? "1 agent in the conversation it was in"
                    : "\(loss.resumed) agents in the conversations they were in")
            }
            lines.append(line + ". Anything else that was running, like a dev server, was not restarted.")
        }
        if loss.survived > 0 {
            lines.append("\(count(loss.survived, "terminal kept", "terminals kept")) running, but will close "
                + "when you quit Wortel. Their agents are resumed when it opens again.")
        }
        if !loss.keeperBack {
            lines.append("Wortel could not start a new keeper, so these terminals close when you quit.")
        }
        lines.append("A Force Quit or Stop Running in Background in the Dock can do this, "
            + "also on an app that was opened from one of these terminals.")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your terminals were stopped"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    // MARK: - Close confirmation

    /// Sheets a warning when closing a session that still has a running
    /// process. `completion(true)` proceeds with the close. Falls back to
    /// closing immediately if there's no window to sheet onto.
    private func confirmClose(_ session: Session, completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.name)”?"
        // Name what dies. The scan is milliseconds, and shared with the check
        // that led here, so it runs inline rather than letting the sheet appear and then change its mind; if it finds
        // nothing nameable (no shell pid on the fallback path, a torn process
        // table) the original wording still stands.
        // The agent too, which closing ends as well, plus anything the session
        // started that has already left its shell.
        let scanned = processes.recentScan()
        let running = scanned.jobs(for: session.id)
            + scanned.orphans.filter { $0.lastSessionID == session.id }
        alert.informativeText = RunningJobs.closeSummary(for: running)
            ?? "A process is still running in this session. Closing it will terminate the process."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// Closing the sidebar's selection: one sheet for the lot, worded as the
    /// single one is, naming what is still running across all of them.
    private func confirmClose(_ batch: [Session], running: [Session], completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(batch.count) Sessions?"
        let scanned = processes.recentScan()
        let ids = Set(running.map(\.id))
        let jobs = running.flatMap { scanned.jobs(for: $0.id) }
            + scanned.orphans.filter { $0.lastSessionID.map(ids.contains) ?? false }
        alert.informativeText = RunningJobs.closeSummary(for: jobs)
            ?? (running.count == 1
                ? "A process is still running in \u{201c}\(running[0].name)\u{201d}. Closing it will terminate the process."
                : "Processes are still running in \(running.count) of these sessions. Closing them will terminate the processes.")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Preview windows

    /// Repo root per directory. The answer never changes for a given directory
    /// in a session, and asking git twice for the same one is a process we
    /// don't need to spawn.
    private var repoRootCache: [String: String?] = [:]

    /// Where a file being opened goes: where files go (⌥: the other place,
    /// this once), or exactly where a dragged file was dropped.
    private enum FilePlacement {
        case home(elsewhere: Bool)
        case dropped(TabRegion, index: Int)
    }

    /// Open a file in a preview window, working out what its diff should be.
    ///
    /// A file the repo already knows is changed opens on *its* row's diff, which
    /// is what the Changes pane would have shown; anything else in a repo gets
    /// everything since HEAD, because that's the question you're asking when you
    /// point at a file rather than at one side of its change. Outside a repo
    /// there's no diff to offer and the window says so by not having the mode.
    ///
    /// Deliberately **not** dependent on the git panel being open. The panel
    /// resolves its repo only while it's visible — a good rule for a panel that
    /// would otherwise run git for a column nobody is looking at, and exactly
    /// the wrong one here: it meant a file opened with the inspector closed had
    /// no repo, so no diff source, so no Diff mode at all. When the panel
    /// happens to have the answer it's free; when it doesn't, we ask.
    /// A path ⌘-clicked in a terminal, already found on disk. Every file
    /// opens here, in the preview, at the line its `:42` named: a click looks
    /// at what an agent did and never launches anything (a `.command` file in
    /// its default app runs). A folder is the one thing the preview can't
    /// show, so it goes to Finder; a package is only revealed there, since
    /// opening an app runs it (`MarkdownLinkTarget.package`).
    private func openTerminalLink(_ target: TerminalLink.Target) {
        switch target.kind {
        case .markdown, .file: openPreview(target.url, line: target.line)
        case .folder: NSWorkspace.shared.open(target.url)
        case .package: NSWorkspace.shared.activateFileViewerSelecting([target.url])
        }
    }

    private func openPreview(_ requested: URL, line: Int? = nil) {
        // ⌥ read now, at the click: the open can land after a git lookup, and
        // by then there's no event to ask.
        openPreview(requested, placement: .home(elsewhere: Self.optionClicked), line: line)
    }

    private func openPreview(_ requested: URL, placement: FilePlacement, line: Int? = nil) {
        // Two paths, deliberately: git and the window registry work on the real
        // file, while the window is opened with the path you actually clicked so
        // it can tell you when that was an alias.
        let url = requested.resolvingSymlinksInPath().standardizedFileURL
        // Already open, in a tab or a window: bring it forward (or, dropped,
        // move it there) and do no git work whatsoever.
        if manager.selected?.workspace.region(of: .file(url.path)) != nil {
            place(.file(url.path), placement)
            if let line { previewTabs.reveal(line: line, in: url) }
            return
        }
        if case .home = placement, previewWindows.focus(url) {
            if let line { previewWindows.reveal(line: line, in: url) }
            return
        }

        // The panel already knows this repo and its status — free, and it also
        // knows *which side* of a change the file is on.
        if let repo = gitPanel.repo, let relative = Self.relativePath(of: url, in: repo.root) {
            let change = repo.status.unstagedChanges.first { $0.path == relative }
                ?? repo.status.stagedChanges.first { $0.path == relative }
            if let change {
                presentPreview(requested, diff: .change(root: repo.root, change: change),
                               hasChanges: true, placement: placement, line: line)
            } else {
                presentPreview(
                    requested,
                    diff: .workingTree(root: repo.root, path: relative, untracked: false),
                    placement: placement, line: line)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let directory = url.deletingLastPathComponent().path
            let root: String?
            if let cached = repoRootCache[directory] {
                root = cached
            } else {
                root = await GitService.repoRoot(for: directory)
                repoRootCache[directory] = root
            }
            guard let root, let relative = Self.relativePath(of: url, in: root) else {
                presentPreview(requested, placement: placement, line: line)
                return
            }
            // One line of porcelain, not a patch: it decides whether the window
            // opens on the diff or on the file, and whether that diff is against
            // HEAD or against nothing at all.
            let state = await GitService.workingTreeState(root: root, path: relative)
            presentPreview(
                requested,
                diff: .workingTree(root: root, path: relative, untracked: state == .untracked),
                hasChanges: state.hasChanges, placement: placement, line: line)
        }
    }

    /// Whether the click (or key) doing this held ⌥: open in the other place.
    private static var optionClicked: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
    }

    /// Show a file: as a tab where files go (the main area, where there's
    /// room to read it, until you drag one somewhere else), or where it
    /// already is.
    ///
    /// ⌥-click puts it in the other place this once. Read off the event that's
    /// opening it, so every place a file opens from (the changes list,
    /// History, the file tree, a path in a terminal, a link in Markdown) gets
    /// it without each passing it along.
    private func presentPreview(_ url: URL, diff: PreviewDiffSource = .none,
                                hasChanges: Bool = false, mode: PreviewMode? = nil,
                                placement: FilePlacement? = nil, line: Int? = nil) {
        let tab = previewTabs.tab(for: url, diff: diff, hasChanges: hasChanges, mode: mode)
        place(tab, placement ?? .home(elsewhere: Self.optionClicked))
        // Only for a tab that is there: a line kept for one that never opened
        // would land on the next, unrelated open of the file.
        if let line, manager.selected?.workspace.region(of: tab) != nil {
            previewTabs.reveal(line: line, in: url)
        }
    }

    private func place(_ tab: SideTab, _ placement: FilePlacement) {
        switch placement {
        case .home(let elsewhere): gitPanel.openAtHome(tab, elsewhere: elsewhere)
        case .dropped(let region, let index): gitPanel.openDropped(tab, in: region, at: index)
        }
    }

    private static func relativePath(of url: URL, in root: String) -> String? {
        let path = url.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Menu actions (reached via the responder chain, target nil)

    /// Every command below acts on the session list, which lives in the main
    /// window — and the menu's key equivalents fire wherever you are. With a
    /// preview window key that means ⌘N would open a session behind the window
    /// you're looking at, and ⌘R would start an inline rename in a sidebar you
    /// can't see. So a session command brings its own window forward first.
    ///
    /// ⌘W is the exception and gets its own handling: it closes what you're
    /// looking at.
    private func focusMainWindow() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    @objc func newSession(_ sender: Any?) {
        focusMainWindow()
        manager.newSession(starting: .preferred)
    }

    /// ⌃⌘N, New Terminal: ⌘N without the command Settings names. The item is
    /// only there while there is one (`MainMenu`).
    @objc func newTerminalSession(_ sender: Any?) {
        focusMainWindow()
        manager.newSession(via: .terminal, starting: .plain)
    }

    @objc func newHomeSession(_ sender: Any?) {
        focusMainWindow()
        manager.newHomeSession(starting: .preferred)
    }

    @objc func newWorktreeSession(_ sender: Any?) {
        focusMainWindow()
        newWorktreeSessionFromSheet(manager)
    }

    /// Bring the window forward *before* the panel, not after: the open panel is
    /// modal, so ordering the window front once it's up does nothing until it
    /// closes, and the sidebar the new session appears in would be behind
    /// whatever you were looking at.
    @objc func openFolder(_ sender: Any?) {
        focusMainWindow()
        openFolderSession(manager)
    }

    /// ⌘W closes **what you are looking at**. With a preview window key that is
    /// the preview — closing a session from a file window is destructive, and no
    /// Mac app does that with ⌘W. In the main window it closes the tab in
    /// front of the area you're in, and the session only when that's the
    /// session's own terminal: the menu item says "Close Tab".
    @objc func closeSession(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(sender)
            return
        }
        // ⌘W closes what's in front of the area you're in (the one you last
        // clicked, typed, picked a tab or ⌘]-ed into): a terminal, a browser,
        // a file, a pane. Only the session's own terminal in front of the
        // main area means the session, as closing a terminal's last tab does.
        if let tab = gitPanel.activeTab(in: focusedRegion()), tab != .session {
            gitPanel.requestClose(tab)
            return
        }
        // The empty page after the last session closed: ⌘W is the window's,
        // and the app goes with it.
        if manager.sessions.isEmpty {
            window?.performClose(sender)
            return
        }
        manager.requestCloseSelected()
    }

    /// ⌘⌥S and the titlebar's sidebar buttons. A command of Wortel's own
    /// rather than AppKit's `toggleSidebar:`, because that one is answered by
    /// whatever in the responder chain implements it first, and SwiftUI's
    /// hosting views (the terminal sits in one) do, for SwiftUI's sidebars:
    /// the command stopped there and never reached the window's split. Nothing
    /// else implements this name, so it arrives here and goes straight to it.
    @objc func toggleSessionSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    // MARK: - Side column tabs

    /// The area you're working in: the last one you clicked or typed in,
    /// picked a tab in, or moved to (`GitPanelModel.lastRegion`), if it's
    /// still showing. Not
    /// the first responder alone: a file tab never takes the keyboard, so after
    /// picking one in the column the keyboard is still in the main terminal,
    /// and "move this tab" would have moved the wrong one.
    private func focusedRegion() -> TabRegion {
        switch gitPanel.lastRegion {
        case .side: return gitPanel.isVisible ? .side : .main
        case .bottom: return gitPanel.bottomVisible ? .bottom : .main
        case .main: return .main
        }
    }

    /// Typing in, or focusing, a terminal puts you in its area.
    private func noteKeyboardActivity(in surface: SurfaceView) {
        guard let session = manager.selected else { return }
        let region: TabRegion
        if surface === session.surfaceView {
            // Wherever its row is: a session's own terminal can be moved to
            // the column or the strip.
            region = session.workspace.region(of: .session) ?? .main
        } else if let id = session.sideSurfaces.first(where: { $0.value === surface })?.key,
                  let row = session.workspace.region(of: .terminal(id)) {
            region = row
        } else {
            return
        }
        if gitPanel.lastRegion != region { gitPanel.lastRegion = region }
    }

    /// The areas in the order ⌘] walks them: left to right as they sit, then
    /// the strip.
    private var visibleRegions: [TabRegion] {
        var regions: [TabRegion] = [.main]
        if gitPanel.isVisible {
            gitPanel.columnLeading ? regions.insert(.side, at: 0) : regions.append(.side)
        }
        if gitPanel.bottomVisible { regions.append(.bottom) }
        return regions
    }

    /// ⌘] / ⌘[. With the keyboard in a browser's page they are Forward and
    /// Back, as in every browser, for as long as the page has somewhere to go;
    /// a page with no history that way lets the key through to the areas, so
    /// the keyboard is never stuck in a page.
    @objc func focusNextArea(_ sender: Any?) {
        if let page = keyboardBrowserPage, page.canGoForward { return page.goForward() }
        stepArea(1)
    }

    @objc func focusPreviousArea(_ sender: Any?) {
        if let page = keyboardBrowserPage, page.canGoBack { return page.goBack() }
        stepArea(-1)
    }

    /// The browser whose page has the keyboard, if one does.
    private var keyboardBrowserPage: BrowserPage? {
        BrowserTabs.shared.page(holding: window?.firstResponder)
    }

    private func stepArea(_ offset: Int) {
        let regions = visibleRegions
        guard regions.count > 1, let index = regions.firstIndex(of: focusedRegion()) else { return }
        gitPanel.focus(regions[(index + offset + regions.count) % regions.count])
    }

    @objc func newTerminalHere(_ sender: Any?) {
        focusMainWindow()
        switch focusedRegion() {
        case .main: gitPanel.openMainTerminal()
        case .side: gitPanel.openTerminal()
        case .bottom: gitPanel.openBottomTerminal()
        }
    }

    /// View ▸ Sort Unread First: sessions that want you drawn first in each
    /// sidebar section. A checkmark in the menu, not a row in Settings: it
    /// is flipped while working, as a Finder window's sorting is.
    @objc func toggleSortUnreadFirst(_ sender: Any?) {
        manager.sortUnreadFirst.toggle()
    }

    /// ⇧⌘L: a new browser in the row you're in.
    @objc func newBrowserHere(_ sender: Any?) {
        focusMainWindow()
        gitPanel.openBrowser(at: nil, in: focusedRegion())
    }

    /// ⌘L: the address field of the browser in front, the area you're in
    /// first.
    @objc func openBrowserLocation(_ sender: Any?) {
        focusMainWindow()
        guard let id = frontBrowser() else { return }
        // The keyboard is going there, so that's the area you're in: ⌘W next
        // closes that browser, not what was in front where you were.
        if let region = manager.selected?.workspace.region(of: .browser(id)) { gitPanel.lastRegion = region }
        BrowserTabs.shared.page(for: id).focusAddress()
    }

    private func frontBrowser() -> UUID? {
        let regions: [TabRegion] = [focusedRegion(), .side, .main, .bottom]
        let visible = regions.filter { region in
            switch region {
            case .main: return true
            case .side: return gitPanel.isVisible
            case .bottom: return gitPanel.bottomVisible
            }
        }
        return visible.lazy.compactMap { self.gitPanel.activeTab(in: $0)?.browserID }.first
    }

    /// ⌘R: reload the browser in front, the area you're in first. It works
    /// from the terminal too, which is the point: change something, ⌘R, look.
    @objc func reloadBrowserPage(_ sender: Any?) {
        guard let id = frontBrowser() else { return }
        BrowserTabs.shared.page(for: id).reload()
    }

    /// ⇧⌘R: the same, past the cache.
    @objc func forceReloadBrowserPage(_ sender: Any?) {
        guard let id = frontBrowser() else { return }
        BrowserTabs.shared.page(for: id).reloadFromOrigin()
    }

    /// ⌥⌘I: Web Inspector for the browser in front, or away again.
    @objc func showWebInspector(_ sender: Any?) {
        guard let id = frontBrowser() else { return }
        BrowserTabs.shared.page(for: id).toggleInspector()
    }

    /// ⌘+ / ⌘- / ⌘0 with the keyboard in a browser's page zoom the page. The
    /// same selectors a terminal answers for its font size: the responder
    /// chain reaches a focused terminal first, and gets here only when there
    /// is none.
    @objc func increaseFontSize(_ sender: Any?) { keyboardBrowserPage?.zoom(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { keyboardBrowserPage?.zoom(by: -1) }
    @objc func resetFontSize(_ sender: Any?) { keyboardBrowserPage?.zoom(by: 0) }

    /// ⌘/: the shortcut list, on the site because that is the one copy that
    /// is kept.
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://wortel.sh/docs#shortcuts")!)
    }

    /// A new mail to us, with the three facts every report needs already in
    /// it, where the person can read them before anything is sent. Mail rather
    /// than a form or a PostHog survey: it goes nowhere until they press Send,
    /// it says exactly what it carries, and a reply is one click away.
    @objc func sendFeedback(_ sender: Any?) {
        let device = TelemetryClient.deviceProperties()
        let chip = device["arch"] == "arm64" ? "Apple Silicon" : "Intel"
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = "hello@wortel.sh"
        mail.queryItems = [
            URLQueryItem(name: "subject", value: "Wortel feedback"),
            URLQueryItem(name: "body", value: """



                Wortel \(device["app_version"] ?? "unknown"), macOS \(device["macos"] ?? "unknown"), \(chip)
                """),
        ]
        if let url = mail.url { NSWorkspace.shared.open(url) }
    }

    @objc func newBottomTerminal(_ sender: Any?) {
        focusMainWindow()
        gitPanel.openBottomTerminal()
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        gitPanel.selectTab(number: sender.tag, in: focusedRegion())
    }

    /// Install the downloaded update and relaunch: the update icon's popover,
    /// the Wortel menu, ⌘P.
    @objc func restartToUpdate(_ sender: Any?) {
        updater.restartToUpdate()
    }

    /// Wortel ▸ Settings… (⌘,). One window, made when asked for and let go
    /// when it closes.
    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.show()
            return
        }
        let controller = SettingsWindowController(settings: .shared, updater: updater)
        controller.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = controller
        controller.show()
    }

    /// ⌃⌘1 — open Changes, bring it forward, or close it, as ⌃⌘2 does History.
    @objc func showChanges(_ sender: Any?) {
        focusMainWindow()
        gitPanel.activate(.changes, via: .shortcut)
    }

    @objc func showHistory(_ sender: Any?) {
        focusMainWindow()
        gitPanel.activate(.history, via: .shortcut)
    }

    @objc func closeWholeSession(_ sender: Any?) {
        manager.requestCloseSelected()
    }

    /// Move the tab in front of the row you're in to the area in `direction`.
    /// Sideways crosses between the main area and the column, whichever side
    /// the column is on; down puts a terminal in the strip, up brings it back
    /// to the main area. The session's own terminal moving sideways swaps sides.
    private func moveFocusedTab(_ direction: NSRectEdge) {
        let from = focusedRegion()
        guard let tab = gitPanel.activeTab(in: from) else { return }
        let columnOnLeft = gitPanel.columnLeading
        var target: TabRegion?
        switch (from, direction) {
        case (.main, .minX): target = columnOnLeft ? .side : nil
        case (.main, .maxX): target = columnOnLeft ? nil : .side
        case (.side, .minX): target = columnOnLeft ? nil : .main
        case (.side, .maxX): target = columnOnLeft ? .main : nil
        case (.main, .minY), (.side, .minY): target = .bottom
        case (.bottom, .maxY): target = .main
        default: target = nil
        }
        guard let target else { return }
        if tab == .session {
            if target == .side { gitPanel.setColumnLeading(!columnOnLeft) }
            return
        }
        gitPanel.move(tab, to: target, at: .max)
    }

    @objc func moveTabLeft(_ sender: Any?) { moveFocusedTab(.minX) }
    @objc func moveTabRight(_ sender: Any?) { moveFocusedTab(.maxX) }
    @objc func moveTabDown(_ sender: Any?) { moveFocusedTab(.minY) }
    @objc func moveTabUp(_ sender: Any?) { moveFocusedTab(.maxY) }

    /// Let a file's document go, unless another session still has it open:
    /// documents are one per file for the whole app, tabs are per session.
    private func releaseFile(_ path: String) {
        guard !manager.sessions.contains(where: { $0.workspace.region(of: .file(path)) != nil }) else { return }
        previewTabs.forget(path)
    }

    /// ⌘F with a file tab showing: that file's find bar, as a preview window's.
    /// The tab in front of the area you're in first, then any area's. With no
    /// searchable file on screen the item is disabled and ⌘F goes on to the
    /// terminal, as it always has.
    @objc func showPreviewFind(_ sender: Any?) {
        guard let path = findableFileTab() else { return }
        // As ⌘L: the find bar has the keyboard, so its area is the one you're in.
        if let region = manager.selected?.workspace.region(of: .file(path)) { gitPanel.lastRegion = region }
        previewTabs.document(for: path).find.isPresented = true
    }

    /// ⌘G / ⇧⌘G: the next and previous match of the find bar that's open.
    @objc func previewFindNext(_ sender: Any?) { openFind()?.next() }
    @objc func previewFindPrevious(_ sender: Any?) { openFind()?.previous() }

    /// The find bar of the file tab ⌘F would pick, if it's up.
    private func openFind() -> PreviewFind? {
        guard let path = findableFileTab() else { return nil }
        let find = previewTabs.document(for: path).find
        return find.isPresented ? find : nil
    }

    private func findableFileTab() -> String? {
        let fronts = [focusedRegion(), .side, .main, .bottom].map { gitPanel.activeTab(in: $0) }
        for case let path? in fronts.map({ $0?.filePath }) {
            let document = previewTabs.document(for: path).document
            if document.mode != .rendered, !document.isBinary { return path }
        }
        return nil
    }

    @objc func toggleSideColumn(_ sender: Any?) {
        focusMainWindow()
        gitPanel.toggle()
    }

    @objc func toggleBottomStrip(_ sender: Any?) {
        focusMainWindow()
        gitPanel.toggleBottom()
    }

    @objc func toggleColumnSide(_ sender: Any?) {
        focusMainWindow()
        gitPanel.setColumnLeading(!gitPanel.columnLeading)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        focusMainWindow()
        gitPanel.reopenClosedTab(in: focusedRegion())
    }

    @objc func newSideTerminal(_ sender: Any?) {
        focusMainWindow()
        gitPanel.openTerminal()
    }

    @objc func selectNextSideTab(_ sender: Any?) {
        gitPanel.selectAdjacent(1, in: focusedRegion())
    }

    @objc func selectPreviousSideTab(_ sender: Any?) {
        gitPanel.selectAdjacent(-1, in: focusedRegion())
    }

    /// Ask before a side terminal takes a running program down with it: the
    /// dev server you opened it for is exactly what a stray ⌘W would kill.
    private func confirmCloseSideTerminal(count: Int, _ proceed: @escaping () -> Void) {
        guard let window else { return proceed() }
        let alert = NSAlert()
        if count == 1 {
            alert.messageText = "Close this terminal?"
            alert.informativeText = "A program is still running in it, and closing the tab stops it."
        } else {
            alert.messageText = "Close \(count) terminals?"
            alert.informativeText = "Programs are still running in them, and closing the tabs stops them."
        }
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    private lazy var sessionSwitcher = SessionSwitcher(manager: manager) { [weak self] text in
        self?.insertPrompt(text)
    }

    /// ⌘P: go to a session by name, folder, branch or directory.
    @objc func showSessionSwitcher(_ sender: Any?) {
        // ⌘P again puts it away. Before focusing the window: that would take
        // the keyboard from the switcher, which closes it, and this would open
        // a new one.
        if sessionSwitcher.isShown { return sessionSwitcher.close() }
        focusMainWindow()
        guard let window else { return }
        sessionSwitcher.toggle(over: window)
    }

    /// ⌘Y: the prompts typed to agents, from the agents' own history files.
    /// From any other mode of the panel it switches to this one; from this
    /// one it puts the panel away, as ⌘P does.
    @objc func showPromptHistory(_ sender: Any?) {
        if sessionSwitcher.isShown {
            let wasPrompts = sessionSwitcher.isShowingPrompts
            sessionSwitcher.close()
            if wasPrompts { return }
        }
        focusMainWindow()
        guard let window else { return }
        sessionSwitcher.showPrompts(over: window, from: manager.branchSource())
    }

    /// A prompt picked from the history, typed into the selected session's
    /// own terminal and **not sent**: the same paste ⌘V makes
    /// (`SurfaceView.sendText`, which libghostty brackets when the program
    /// asked for `?2004`, so a multi-line prompt stays one input). Its
    /// terminal comes to the front of the main area if a tab was over it,
    /// and gets the keyboard, so Return (or an edit first) is yours.
    private func insertPrompt(_ text: String) {
        guard let session = manager.selected, let surface = session.surfaceView else { return }
        gitPanel.selectMain(.session)
        let bracketed = TerminalModeRecorder.shared.modes(for: session.id).bracketedPaste
        surface.sendText(PromptHistory.insertion(text, bracketed: bracketed))
        if gitPanel.activeMainTab == nil { window?.makeFirstResponder(surface) }
    }

    /// ⇧⌘P: the palette with only the menus' commands.
    @objc func showCommandPalette(_ sender: Any?) {
        if sessionSwitcher.isShown { return sessionSwitcher.close() }
        focusMainWindow()
        guard let window else { return }
        sessionSwitcher.toggle(over: window, commandsOnly: true)
    }

    /// ⌥⌘P: pin the selected session to the top of the sidebar, or unpin it.
    @objc func togglePinSession(_ sender: Any?) {
        focusMainWindow()
        guard let session = manager.selected else { return }
        manager.setPinned(session, !manager.isPinned(session))
    }

    /// ⇧⌘U: the "not caught up" ring on the selected session, until you've
    /// spent time in it again.
    @objc func markSessionUnread(_ sender: Any?) {
        guard let session = manager.selected else { return }
        manager.markUnread(session)
    }

    /// Session ▸ Remind Me ▸ a preset (its index in `tag`), on the selected
    /// session.
    @objc func remindSession(_ sender: Any?) {
        guard let session = manager.selected, let item = sender as? NSMenuItem,
              ReminderTime.Preset.allCases.indices.contains(item.tag) else { return }
        manager.setReminder(session, at: ReminderTime.date(for: ReminderTime.Preset.allCases[item.tag], now: Date()))
    }

    @objc func remindSessionCustom(_ sender: Any?) {
        guard let session = manager.selected else { return }
        ReminderDialog.present(on: window, initial: session.remindAt) { [manager] date in
            manager.setReminder(session, at: date)
        }
    }

    @objc func cancelSessionReminder(_ sender: Any?) {
        guard let session = manager.selected else { return }
        manager.setReminder(session, at: nil)
    }

    /// Session ▸ Colour: the item's colour (none for None) on the selected
    /// session.
    @objc func setSessionColour(_ sender: Any?) {
        guard let session = manager.selected, let item = sender as? NSMenuItem else { return }
        manager.setColour(session, (item.representedObject as? String).flatMap(SessionColour.init(rawValue:)))
    }

    @objc func cleanUpWorktrees(_ sender: Any?) {
        focusMainWindow()
        guard let window else { return }
        WorktreeCleanupSheet.present(manager: manager, over: window)
    }

    @objc func renameSession(_ sender: Any?) {
        focusMainWindow()
        manager.beginRenameSelected()
    }

    @objc func selectNextSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectNext()
    }

    @objc func selectPreviousSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectPrevious()
    }

    /// ⌃⌘[ / ⌃⌘] and the sidebar row's arrows: back and forth through the
    /// places you've been, a session and the tab you had in front in it
    /// (SessionManager's Back and Forward).
    @objc func goBackSession(_ sender: Any?) {
        focusMainWindow()
        manager.goBack(bringForward: bringForwardOnStep)
    }

    @objc func goForwardSession(_ sender: Any?) {
        focusMainWindow()
        manager.goForward(bringForward: bringForwardOnStep)
    }

    /// A step's tab, brought forward in whichever row it is in now. The
    /// selection has just moved, and the panel would follow it from
    /// ContentView's `onChange`, but only later; pointing it at the session
    /// here first (the same call, so doing it twice changes nothing) is what
    /// makes the tab come forward in the right session.
    private func bringForwardOnStep(_ session: Session, _ tab: SideTab) {
        if gitPanel.session !== session {
            gitPanel.focus(session: session)
            fileTree.focus(session: session)
        }
        guard let region = session.workspace.region(of: tab) else { return }
        gitPanel.bringForward(tab, in: region)
    }

    @objc func selectNextAttentionSession(_ sender: Any?) {
        focusMainWindow()
        manager.selectNextAttention()
    }

    @objc func selectSessionAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        focusMainWindow()
        manager.select(index: item.tag)
    }

    /// ⌘⌥G — show, swap to, or close the source-control side of the inspector.
    /// It lands on whichever git pane was last chosen, so coming back from Files
    /// returns you to History if that's where you were.
    @objc func toggleSourceControl(_ sender: Any?) {
        focusMainWindow()
        gitPanel.activate(GitPanelModel.lastSourceControlPane, via: .shortcut)
    }

    /// ⌘⌥E — the same rule for the Files pane.
    @objc func toggleFileTree(_ sender: Any?) {
        // As ⌃⌘1 and ⌃⌘2: from a preview window, act on the window you'll see.
        focusMainWindow()
        gitPanel.activate(.files, via: .shortcut)
    }

    /// The pane ⌃⌘1, ⌃⌘2 or ⌃⌘3 opens, for the menu titles.
    private static func pane(toggledBy action: Selector?) -> InspectorPane? {
        switch action {
        case #selector(showChanges(_:)): return .changes
        case #selector(showHistory(_:)): return .history
        case #selector(toggleFileTree(_:)): return .files
        default: return nil
        }
    }

    @objc func focusSourceControlList(_ sender: Any?) {
        gitPanel.requestListFocus()
    }

    @objc func showPermissions(_ sender: Any?) {
        PermissionsNotice.shared.showFromMenu()
    }

    /// Session ▸ Update Pi…: the selected session's agent is a version too
    /// old to say what it is doing. Opens what the sidebar's warning icon
    /// opens.
    @objc func updateSessionAgent(_ sender: Any?) {
        guard let reporter = manager.selected?.silentAgent.flatMap({ ReportedStatus.knownReporters[$0] })
        else { return }
        AgentUpdateNotice.shared.showFromMenu(for: reporter)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// Flip anonymous reporting: the action of the switch in the sidebar's
    /// ⓘ, which reaches here through the responder chain. The Settings row
    /// sets the same preference through the same funnel
    /// (`Telemetry.setReporting`). See `Wortel/Telemetry/` for what it can
    /// send, which is a list short enough to read.
    @objc func toggleTelemetry(_ sender: Any?) {
        Telemetry.setReporting(!TelemetrySettings.isEnabledByUser)
    }

    /// Grey out "Check for Updates…" while a check is already in flight (Sparkle
    /// drops `canCheckForUpdates` to false for the duration).
    ///
    /// **Only called because the class declares `NSMenuItemValidation`.** A
    /// Swift method on an NSObject subclass is not exposed to Objective-C
    /// unless it satisfies an `@objc` requirement, and AppKit asks through the
    /// runtime. Without the declaration this compiled, never ran, and every
    /// rule below was dead: no checkmarks on the Wortel menu's switches, no
    /// Show/Hide titles, nothing greyed out, ⌘F never falling through to the
    /// terminal. Found 2026-10-07 from a missing checkmark.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSortUnreadFirst(_:)) {
            menuItem.state = manager.sortUnreadFirst ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleSessionSidebar(_:)) {
            menuItem.title = splitController.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        }
        // Nothing to act on without a session, and nowhere to step to with one.
        if menuItem.action == #selector(renameSession(_:))
            || menuItem.action == #selector(closeWholeSession(_:)) {
            return manager.selected != nil
        }
        if menuItem.action == #selector(goBackSession(_:)) { return manager.canGoBack }
        if menuItem.action == #selector(goForwardSession(_:)) { return manager.canGoForward }
        if menuItem.action == #selector(selectPreviousSession(_:))
            || menuItem.action == #selector(selectNextSession(_:)) {
            return manager.sessions.count > 1
        }
        if menuItem.action == #selector(markSessionUnread(_:)) {
            return manager.selected != nil
        }
        if menuItem.action == #selector(updateSessionAgent(_:)) {
            let reporter = manager.selected?.silentAgent.flatMap { ReportedStatus.knownReporters[$0] }
            menuItem.isHidden = reporter == nil
            if let reporter { menuItem.title = AgentUpdateWords.menuItem(for: reporter) }
            return reporter != nil
        }
        if menuItem.action == #selector(remindSession(_:)) || menuItem.action == #selector(remindSessionCustom(_:)) {
            return manager.selected != nil
        }
        if menuItem.action == #selector(cancelSessionReminder(_:)) {
            return manager.selected?.remindAt != nil
        }
        if menuItem.action == #selector(setSessionColour(_:)) {
            let colour = (menuItem.representedObject as? String).flatMap(SessionColour.init(rawValue:))
            menuItem.state = manager.selected.map { $0.colour == colour } == true ? .on : .off
            return manager.selected != nil
        }
        if menuItem.action == #selector(togglePinSession(_:)) {
            menuItem.title = manager.selected.map(manager.isPinned) == true ? "Unpin Session" : "Pin Session"
            return manager.selected != nil
        }
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updater.canCheckForUpdates
        }
        // Each pane command reads "Hide" only when *its* pane is the one on
        // screen — with Files up, ⌘⌥G swaps rather than closes, so calling it
        // "Hide Source Control" would describe the wrong action.
        // The panes' Show/Hide, by what the key would actually do to them.
        if let pane = Self.pane(toggledBy: menuItem.action) {
            let hides = gitPanel.activateHides(pane)
            menuItem.title = (hides ? "Hide " : "Show ") + pane.title
            return true
        }
        if menuItem.action == #selector(toggleSourceControl(_:)) {
            let hides = gitPanel.activateHides(GitPanelModel.lastSourceControlPane)
            menuItem.title = hides ? "Hide Source Control" : "Show Source Control"
            return true
        }
        if menuItem.action == #selector(toggleBottomStrip(_:)) {
            menuItem.title = gitPanel.bottomVisible ? "Hide Bottom Strip" : "Show Bottom Strip"
            return true
        }
        if menuItem.action == #selector(showPreviewFind(_:)) {
            return findableFileTab() != nil
        }
        if menuItem.action == #selector(previewFindNext(_:))
            || menuItem.action == #selector(previewFindPrevious(_:)) {
            return openFind()?.matches.isEmpty == false
        }
        if menuItem.action == #selector(showWebInspector(_:)) {
            let page = frontBrowser().flatMap { BrowserTabs.shared.existingPage(for: $0) }
            menuItem.title = page?.isInspectorVisible == true ? "Hide Web Inspector" : "Show Web Inspector"
            return page != nil
        }
        if menuItem.action == #selector(openBrowserLocation(_:))
            || menuItem.action == #selector(reloadBrowserPage(_:))
            || menuItem.action == #selector(forceReloadBrowserPage(_:)) {
            return frontBrowser() != nil
        }
        if menuItem.action == #selector(increaseFontSize(_:))
            || menuItem.action == #selector(decreaseFontSize(_:))
            || menuItem.action == #selector(resetFontSize(_:)) {
            return keyboardBrowserPage != nil
        }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return gitPanel.canReopenClosedTab
        }
        if menuItem.action == #selector(toggleColumnSide(_:)) {
            menuItem.title = gitPanel.columnLeading
                ? "Move Side Column to the Right" : "Move Side Column to the Left"
            return true
        }
        if menuItem.action == #selector(toggleSideColumn(_:)) {
            menuItem.title = gitPanel.isVisible ? "Hide Side Column" : "Show Side Column"
            return true
        }
        if menuItem.action == #selector(selectNextSideTab(_:))
            || menuItem.action == #selector(selectPreviousSideTab(_:)) {
            return gitPanel.tabs(in: focusedRegion()).count > 1
        }
        if menuItem.action == #selector(focusNextArea(_:))
            || menuItem.action == #selector(focusPreviousArea(_:)) {
            return visibleRegions.count > 1 || keyboardBrowserPage != nil
        }

        // Only offer "Next Waiting Session" when something is actually waiting.
        if menuItem.action == #selector(selectNextAttentionSession(_:)) {
            return manager?.hasAttention ?? false
        }
        return true
    }
}
