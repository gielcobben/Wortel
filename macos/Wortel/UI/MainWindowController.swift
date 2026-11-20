import AppKit

/// One main window and what is one per window: its split (sessions, the
/// main area, the side column), its titlebar rows, and the models that follow
/// the session it has in front (the git panel and the file tree). Its share
/// of the session list is `home`; the list itself is the manager's, one for
/// the app.
///
/// Built by `AppDelegate`, which also wires what each window's models ask of
/// the app (opening a file, a close question, a sheet). The delegate's menu
/// actions act on the active window's (`SessionManager.activeWindow`).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let home: SessionWindow
    let window: NSWindow
    let gitPanel = GitPanelModel()
    let fileTree: FileTreeModel
    let titleBars: TitleBarController
    let split: MainSplitViewController
    private var movability: WindowMovability?

    /// The window is asked to close: the delegate decides (its sessions, if
    /// other windows stay open, close first, with the usual question).
    var shouldClose: (MainWindowController) -> Bool = { _ in true }
    /// The window became key: it is the active one from now.
    var onBecameKey: (MainWindowController) -> Void = { _ in }
    /// The window closed: let it go.
    var onClose: (MainWindowController) -> Void = { _ in }
    /// Moved, resized or occluded.
    var onFrameChanged: (MainWindowController) -> Void = { _ in }
    var onVisibilityChanged: (MainWindowController, Bool) -> Void = { _, _ in }

    init(home: SessionWindow, runtime: GhosttyRuntime, manager: SessionManager,
         processes: ProcessMonitor, previewTabs: PreviewTabs) {
        self.home = home
        fileTree = FileTreeModel(git: gitPanel)
        // A plain NSWindow, built as the one window always was.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // NSWindow's own initializers leave this `true`, and only an
        // NSWindowController turns it off. Under ARC that is an unbalanced
        // release: `close()` frees the window while `window` below still
        // points at it, and the next read of it retains freed memory. It
        // crashed exactly there once: closing the last session changes the
        // selection, which schedules the title observer's task, and the window
        // closed before that task got its turn.
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The titlebar is Wortel's own (see TitleBars.swift): every pane draws
        // its row of it, and the system draws nothing there but the traffic
        // lights. Transparent, so clicks reach the rows under it; no title, the
        // terminal's row shows the session's name itself; no separator, each
        // row draws its own hairline.
        //
        // The toolbar stays, empty, for the one thing only it can do: make the
        // titlebar tall enough for a row of controls and centre the traffic
        // lights in it. Compact is 40pt, next to the ChatGPT app's 42.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        // The window server's own titlebar dragging is off, and the rows start
        // window moves themselves from their empty space (`performWindowDrag`,
        // ChromeBarView). Left on, it moved the window from *anywhere* in the
        // titlebar, tabs included: a tab drag carried the whole window along.
        // On only for the moments tiling needs it (WindowMovability).
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
        self.window = window

        titleBars = TitleBarController(manager: manager, home: home, git: gitPanel, processes: processes)
        split = MainSplitViewController(
            runtime: runtime, manager: manager, home: home, git: gitPanel, files: fileTree,
            titleBars: titleBars, previewTabs: previewTabs)
        super.init()
        home.onSwitch = { [weak split] session in split?.show(session) }
        window.contentViewController = BackdropController(child: split, overlay: titleBars.sidebarControls)
        movability = WindowMovability(window: window)
        titleBars.start()
        window.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        observeTitle()
    }

    /// Where the window goes as it opens: where it was (`windows.json`), or
    /// where a drag let its sessions go, or a step down and right of
    /// `cascadeFrom`, as a new document window is. The first window ever is
    /// where the one window was (its "main" autosave).
    func place(cascadingFrom other: NSWindow?) {
        if let topLeft = home.requestedTopLeft {
            home.requestedTopLeft = nil
            if let other { window.setContentSize(other.contentLayoutRect.size) }
            window.setFrameTopLeftPoint(NSPoint(x: topLeft.x - 40, y: topLeft.y + 20))
        } else if let frame = home.frame {
            window.setFrame(from: frame)
        } else if let other {
            window.setFrame(other.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
        } else {
            window.setFrameUsingName("main")
        }
        if window.frame.height < 320 {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        home.frame = window.frameDescriptor
    }

    /// The window's title is the session's name and nothing else. The path
    /// used to sit under it as a subtitle, which changed on every `cd` and
    /// made the titlebar the one piece of chrome that moved while you typed.
    /// It is also what the Window menu and Mission Control list. Observation
    /// is one-shot, so the observer re-arms after each change.
    private func observeTitle() {
        withObservationTracking {
            _ = home.selected?.name
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyTitle()
                self.observeTitle()
            }
        }
        applyTitle()
    }

    private func applyTitle() {
        window.title = home.selected?.name ?? "Wortel"
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        onVisibilityChanged(self, window.occlusionState.contains(.visible))
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose(self) }

    func windowDidBecomeKey(_ notification: Notification) { onBecameKey(self) }

    func windowWillClose(_ notification: Notification) { onClose(self) }

    func windowDidMove(_ notification: Notification) { frameChanged() }

    func windowDidEndLiveResize(_ notification: Notification) { frameChanged() }

    func windowDidResize(_ notification: Notification) {
        guard !window.inLiveResize else { return }
        frameChanged()
    }

    private func frameChanged() {
        // Not in full screen: the frame to come back to is the one before it.
        guard !window.styleMask.contains(.fullScreen) else { return }
        let descriptor = window.frameDescriptor
        guard descriptor != home.frame else { return }
        home.frame = descriptor
        onFrameChanged(self)
    }
}
