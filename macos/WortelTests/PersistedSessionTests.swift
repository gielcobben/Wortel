import XCTest

/// `PersistedSession` has a hand-written decoder whose `decodeIfPresent`
/// defaults *are* the app's file-format migrations: every one of them is the
/// answer to "what did a file written by an older Wortel mean by leaving this
/// out?". They're only ever exercised on the one launch that reads an old file,
/// which is precisely why they're worth pinning here rather than finding out in
/// the field.
///
/// Fixed JSON rather than a live store: the shapes below are what older builds
/// actually wrote.
final class PersistedSessionTests: XCTestCase {
    private func decode(_ json: String) throws -> PersistedSession {
        try JSONDecoder().decode(PersistedSession.self, from: Data(json.utf8))
    }

    private func decodeList(_ json: String) throws -> [PersistedSession] {
        try JSONDecoder().decode([PersistedSession].self, from: Data(json.utf8))
    }

    // MARK: - Git panel visibility

    /// The one that matters. `false` (you hid the panel on this session) and
    /// absent (the file predates per-session visibility) are both falsy and are
    /// *not* the same thing: only absent may inherit the old app-wide flag. Fold
    /// them together and every session you'd deliberately hidden reopens on the
    /// first launch after the update — for anyone whose old flag was on, which
    /// is the only case where the fallback does anything at all.
    func testHiddenPanelIsDistinguishableFromUnrecorded() throws {
        let hidden = try decode(#"{"id":"\#(UUID())","gitPanelVisible":false}"#)
        XCTAssertEqual(hidden.gitPanelVisible, false, "an explicit false is a decision, not a gap")

        let unrecorded = try decode(#"{"id":"\#(UUID())"}"#)
        XCTAssertNil(unrecorded.gitPanelVisible, "an older file said nothing about the panel")
    }

    func testShownPanelDecodes() throws {
        let shown = try decode(#"{"id":"\#(UUID())","gitPanelVisible":true}"#)
        XCTAssertEqual(shown.gitPanelVisible, true)
    }

    /// Visibility has to survive a save/load cycle in both directions — a `false`
    /// that failed to encode would come back as "unrecorded" and re-inherit the
    /// legacy default, which is the same bug as above by a different route.
    func testVisibilityRoundTrips() throws {
        for visible in [true, false] {
            let original = PersistedSession(
                id: UUID(), name: "Acme/Manager", title: "shell", cwd: "/tmp",
                selected: true, nameSource: "user", gitPanelVisible: visible)
            let data = try JSONEncoder().encode([original])
            let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
            XCTAssertEqual(decoded.first?.gitPanelVisible, visible)
        }
    }

    // MARK: - An agent asleep

    /// A file from before deep sleep has no such agent, and nothing may read
    /// one into it: a session wrongly restored as asleep would sit with no
    /// agent until someone clicked it.
    func testAbsentSleepStaysUnrecorded() throws {
        XCTAssertNil(try decode(#"{"id":"\#(UUID())","runningAgent":"claude"}"#).agentAsleep)
    }

    /// The flag rides beside the agent it is about. An older build drops the
    /// flag and keeps the agent, so it resumes at launch and nothing is lost.
    func testSleepRoundTripsBesideItsAgent() throws {
        let original = PersistedSession(
            id: UUID(), name: "fix login", title: "shell", cwd: "/tmp", selected: false, nameSource: "user",
            gitPanelVisible: nil, runningAgent: "claude", runningArgv: "claude --model opus",
            runningConversationID: "4d98c3d5-653b-4915-8fa3-8db43f551ea7", agentAsleep: "waiting")
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.agentAsleep, "waiting")
        XCTAssertEqual(decoded.runningAgent, "claude")
        XCTAssertEqual(decoded.runningConversationID, "4d98c3d5-653b-4915-8fa3-8db43f551ea7")
    }

    /// The appearance a running agent drew itself for outlives a quit: one
    /// started in light, still running after an update at night, is painted
    /// for light. An older file has none, and says nothing.
    func testWhatAnAgentWasPaintedForRoundTrips() throws {
        let original = PersistedSession(
            id: UUID(), name: "fix login", title: "shell", cwd: "/tmp", selected: false, nameSource: "user",
            gitPanelVisible: nil, runningAgent: "codex", agentPaintedDark: false)
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.agentPaintedDark, false)
        XCTAssertNil(try decode(#"{"id":"\#(UUID())","runningAgent":"codex"}"#).agentPaintedDark)
    }

    /// "Typed and not sent" is what gives an agent the long clock, and an
    /// update relaunches the app: the half-written prompt is still there in
    /// the agent, so the note that there may be one has to be too.
    func testWhenTheSessionWasLastTypedIntoSurvivesTheFile() throws {
        let typed = Date(timeIntervalSince1970: 1_795_000_000)
        let original = PersistedSession(
            id: UUID(), name: "fix login", title: "shell", cwd: "/tmp", selected: false, nameSource: "user",
            gitPanelVisible: nil, lastTypedAt: typed)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([PersistedSession].self, from: data).first?.lastTypedAt, typed)
        XCTAssertNil(try decode(#"{"id":"\#(UUID())"}"#).lastTypedAt)
    }

    /// The sidebar's Created and Recent orders read these, and
    /// an update relaunches the app: the order must come back as it was.
    func testWhenTheSessionWasMadeAndLastSentSurviveTheFile() throws {
        let made = Date(timeIntervalSince1970: 1_795_000_000)
        let sent = Date(timeIntervalSince1970: 1_795_000_600)
        let original = PersistedSession(
            id: UUID(), name: "fix login", title: "shell", cwd: "/tmp", selected: false, nameSource: "user",
            gitPanelVisible: nil, createdAt: made, lastSentAt: sent)
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(try JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.createdAt, made)
        XCTAssertEqual(decoded.lastSentAt, sent)
        let old = try decode(#"{"id":"\#(UUID())"}"#)
        XCTAssertNil(old.createdAt, "a file from before reads as unknown, not as now")
        XCTAssertNil(old.lastSentAt)
    }

    // MARK: - Port block

    /// A file from before port blocks has none, and must read as none rather
    /// than as port 0: `restore` gives those sessions a block, and a decoded
    /// zero would be a block nobody can bind.
    func testAbsentPortBlockStaysUnrecorded() throws {
        XCTAssertNil(try decode(#"{"id":"\#(UUID())"}"#).portBase)
    }

    /// The block is what keeps a session's dev server on the same port across a
    /// relaunch, so it has to survive the file.
    func testPortBlockRoundTrips() throws {
        let original = PersistedSession(
            id: UUID(), name: "web", title: "shell", cwd: "/tmp",
            selected: true, nameSource: "user", gitPanelVisible: nil, portBase: 21_340)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([PersistedSession].self, from: data).first?.portBase, 21_340)
    }

    // MARK: - Inspector pane

    /// The pane is per-session, but "no pane recorded" is a real and common
    /// state: a file written before panes were per-session, and a session that
    /// has simply never had one chosen, are the same thing — both defer to the
    /// last pane chosen anywhere (`GitPanelModel.defaultPane`). So nil must stay
    /// nil through the decoder rather than being defaulted to `.changes` here,
    /// or every existing session would be pinned to Changes on the first launch
    /// after the update.
    func testAbsentPaneStaysUnrecorded() throws {
        let session = try decode(#"{"id":"\#(UUID())","gitPanelVisible":true}"#)
        XCTAssertNil(session.inspectorPane, "an older file said nothing about the pane")
    }

    func testRecordedPaneDecodes() throws {
        for raw in ["changes", "history", "files"] {
            let session = try decode(#"{"id":"\#(UUID())","inspectorPane":"\#(raw)"}"#)
            XCTAssertEqual(session.inspectorPane, raw)
        }
    }

    /// The raw string is kept as-is rather than parsed into the enum, so a value
    /// this build doesn't know (a pane added, then removed, or a hand-edited
    /// file) reaches `SessionManager.restore` intact for it to reject — the same
    /// division of labour as `gitPanelVisible`: this type reads the file, the
    /// restore decides what an unusable value means.
    func testUnknownPaneSurvivesDecoding() throws {
        let session = try decode(#"{"id":"\#(UUID())","inspectorPane":"blame"}"#)
        XCTAssertEqual(session.inspectorPane, "blame")
    }

    func testPaneRoundTrips() throws {
        for pane in ["files", nil] {
            let original = PersistedSession(
                id: UUID(), name: "Wortel/App", title: "shell", cwd: "/tmp",
                selected: true, nameSource: "user", gitPanelVisible: true,
                inspectorPane: pane)
            let data = try JSONEncoder().encode([original])
            let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
            XCTAssertEqual(decoded.first?.inspectorPane, pane)
        }
    }

    // MARK: - Side tabs

    /// A file from before the column had tabs says nothing about them, and that
    /// has to reach `restore` as nil, not as an empty strip: nil is what turns
    /// the old visible-and-pane pair into a one-tab strip, where an empty list
    /// would close the column on every session that had it open.
    func testAbsentSideTabsStayUnrecorded() throws {
        let session = try decode(#"{"id":"\#(UUID())","gitPanelVisible":true,"inspectorPane":"history"}"#)
        XCTAssertNil(session.sideTabs)
        XCTAssertNil(session.activeSideTab)
    }

    func testSideTabsRoundTrip() throws {
        let terminal = SideTab.terminal(UUID())
        let tabs = [SideTab.pane(.changes), terminal, .pane(.files)]
        let original = PersistedSession(
            id: UUID(), name: "Wortel/App", title: "shell", cwd: "/tmp",
            selected: true, nameSource: "user", gitPanelVisible: true,
            sideTabs: tabs.map(\.rawValue), activeSideTab: terminal.rawValue)
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.sideTabs?.compactMap(SideTab.init(rawValue:)), tabs)
        XCTAssertEqual(decoded.activeSideTab.flatMap(SideTab.init(rawValue:)), terminal)
    }

    /// Everything the workspace saves beyond the column comes back: the main
    /// row and the strip, what ⌘⇧T can reopen, where browsers are, where
    /// files and browsers open, and the pinned checkout. One of these lost in
    /// the round trip is a row that's empty after an update, with no error.
    func testTheWholeWorkspaceRoundTrips() throws {
        let strip = SideTab.terminal(UUID())
        let browser = SideTab.browser(UUID())
        let file = SideTab.file("/tmp/notes.md")
        let closed = ClosedTab(tab: .pane(.history), region: .side, index: 1)
        let original = PersistedSession(
            id: UUID(), name: "Wortel/App", title: "shell", cwd: "/tmp",
            selected: true, nameSource: "user", gitPanelVisible: false,
            bottomTabs: [strip.rawValue, file.rawValue], activeBottomTab: file.rawValue,
            bottomVisible: true, closedTabs: [closed.rawValue],
            mainTabs: [SideTab.session.rawValue, browser.rawValue], activeMainTab: browser.rawValue,
            sideColumnLeading: true,
            browserAddresses: [browser.browserID!.uuidString: "http://localhost:4321/"],
            gitCheckout: "/tmp/worktree", tabHabits: ["browser": "main"])
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.bottomTabs?.compactMap(SideTab.init(rawValue:)), [strip, file])
        XCTAssertEqual(decoded.activeBottomTab.flatMap(SideTab.init(rawValue:)), file)
        XCTAssertEqual(decoded.bottomVisible, true)
        XCTAssertEqual(decoded.closedTabs?.compactMap(ClosedTab.init(rawValue:)), [closed])
        XCTAssertEqual(decoded.mainTabs?.compactMap(SideTab.init(rawValue:)), [.session, browser])
        XCTAssertEqual(decoded.activeMainTab.flatMap(SideTab.init(rawValue:)), browser)
        XCTAssertEqual(decoded.sideColumnLeading, true)
        XCTAssertEqual(decoded.browserAddresses, [browser.browserID!.uuidString: "http://localhost:4321/"])
        XCTAssertEqual(decoded.gitCheckout, "/tmp/worktree")
        XCTAssertEqual(decoded.tabHabits, ["browser": "main"])
    }

    /// A file from before the main row, the strip, browsers and habits: all
    /// nil, which `restore` reads as none of them.
    func testAnOlderFileHasNoneOfTheNewerFields() throws {
        let session = try decode(#"{"id":"\#(UUID())","gitPanelVisible":false}"#)
        XCTAssertNil(session.mainTabs)
        XCTAssertNil(session.bottomTabs)
        XCTAssertNil(session.browserAddresses)
        XCTAssertNil(session.gitCheckout)
        XCTAssertNil(session.tabHabits)
        XCTAssertNil(session.colour)
    }

    // MARK: - Colour

    func testRecordedColourDecodes() throws {
        for colour in SessionColour.allCases {
            let session = try decode(#"{"id":"\#(UUID())","colour":"\#(colour.rawValue)"}"#)
            XCTAssertEqual(session.colour.flatMap(SessionColour.init(rawValue:)), colour)
        }
    }

    /// A colour only a newer build has is kept as written, for `restore` to
    /// read as none, rather than failing the whole file.
    func testUnknownColourSurvivesDecoding() throws {
        let session = try decode(#"{"id":"\#(UUID())","colour":"teal"}"#)
        XCTAssertEqual(session.colour, "teal")
    }

    func testColourRoundTrips() throws {
        for colour in ["yellow", nil] {
            let original = PersistedSession(
                id: UUID(), name: "Review", title: "shell", cwd: "/tmp",
                selected: false, nameSource: "user", colour: colour, gitPanelVisible: false)
            let data = try JSONEncoder().encode([original])
            let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
            XCTAssertEqual(decoded.first?.colour, colour)
        }
    }

    /// The raw form is the one thing that has to agree between two builds: a
    /// terminal tab's id is also the keeper's session id, so a tab that decodes
    /// to a different id is a shell nobody can reach again.
    func testSideTabRawValues() {
        let id = UUID()
        XCTAssertEqual(SideTab(rawValue: "changes"), .pane(.changes))
        XCTAssertEqual(SideTab(rawValue: "terminal:\(id.uuidString)"), .terminal(id))
        XCTAssertEqual(SideTab.terminal(id).rawValue, "terminal:\(id.uuidString)")
        XCTAssertNil(SideTab(rawValue: "terminal:not-a-uuid"))
        XCTAssertNil(SideTab(rawValue: "browser"))
    }

    // MARK: - Origin directory

    /// Where a session was *born*, which is what a session opened beside it
    /// inherits. It has to be distinguishable from where the shell has since
    /// wandered, because telling them apart is the entire point of recording it:
    /// `cwd` follows every `cd`, and inheriting that is what made a session
    /// opened next to one you'd taken three levels deep start three levels deep
    /// too, with the next one inheriting the drift again.
    func testOriginIsSeparateFromTheDriftedDirectory() throws {
        let session = try decode(#"""
        {"id":"\#(UUID())","cwd":"/Users/me/Developer/wortel/macos/Wortel/Sessions",
         "originCwd":"/Users/me/Developer/wortel"}
        """#)
        XCTAssertEqual(session.cwd, "/Users/me/Developer/wortel/macos/Wortel/Sessions")
        XCTAssertEqual(session.originCwd, "/Users/me/Developer/wortel")
    }

    /// A file written before origins existed left it out, and there is nothing
    /// to recover: the origin was never recorded. It stays nil here — what an
    /// absent one falls back to is `SessionManager.restore`'s decision, and it
    /// falls back to `cwd`, the only evidence there is. That is also exactly
    /// what the old behaviour inherited, so the launch that reads an old file
    /// behaves as it always did and the drift stops from the next session on.
    func testAbsentOriginIsLeftForRestoreToResolve() throws {
        let session = try decode(#"{"id":"\#(UUID())","cwd":"/Users/me/Developer/wortel"}"#)
        XCTAssertNil(session.originCwd, "an older file recorded no origin")
    }

    /// It has to survive a round trip, or every save would quietly downgrade
    /// every session to "no origin recorded" and the drift would come back.
    func testOriginRoundTrips() throws {
        let original = PersistedSession(
            id: UUID(), name: "Wortel/macos", title: "shell",
            cwd: "/Users/me/Developer/wortel/macos",
            originCwd: "/Users/me/Developer/wortel",
            selected: true, nameSource: "placeholder", gitPanelVisible: nil)
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
        XCTAssertEqual(decoded.first?.originCwd, "/Users/me/Developer/wortel")
        XCTAssertEqual(decoded.first?.cwd, "/Users/me/Developer/wortel/macos")
    }

    // MARK: - Older files

    /// A real pre-per-session file: every session decodes, and says nothing about
    /// the panel, so `SessionManager.restore` gives them all the legacy app-wide
    /// flag. The rest of the fields must survive that read untouched.
    func testPreVisibilityFileDecodes() throws {
        let sessions = try decodeList("""
        [{"id":"\(UUID())","name":"Acme/Manager","title":"shell",
          "cwd":"/Users/me/Developer/acme","selected":true,"nameIsUserSet":true},
         {"id":"\(UUID())","name":"Acme/Worker","title":"shell",
          "cwd":"/Users/me/Developer/wortel","selected":false,"nameIsUserSet":true}]
        """)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.gitPanelVisible == nil })
        XCTAssertEqual(sessions.first?.name, "Acme/Manager")
        XCTAssertEqual(sessions.first?.selected, true)
    }

    /// The pre-existing defaults, pinned alongside the new one because they're
    /// the same kind of claim about the same file. A session named before
    /// auto-naming existed counts as user-set so auto-naming never relabels work
    /// the user named by hand.
    func testDefaultsForAMinimalRecord() throws {
        let id = UUID()
        let session = try decode(#"{"id":"\#(id)"}"#)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.title, "shell")
        XCTAssertEqual(session.name, "Session")
        XCTAssertNil(session.cwd)
        XCTAssertNil(session.originCwd)
        XCTAssertFalse(session.selected)
        XCTAssertEqual(session.nameSource, "user", "pre-auto-naming sessions are treated as user-named")
        XCTAssertNil(session.worktreeBranch)
    }

    // MARK: - Name source

    /// The flag `nameSource` replaced. A `true` was the user's rename and is
    /// exactly `user`; a `false` was a default or a model's guess, and both are
    /// things anything may now replace. Mapping `false` to `model` instead
    /// would let a stale guess outrank nothing and block nothing, but it would
    /// also claim the model had spoken where it never did.
    func testLegacyUserSetFlagMigratesToASource() throws {
        let named = try decode(#"{"id":"\#(UUID())","nameIsUserSet":true}"#)
        XCTAssertEqual(named.nameSource, "user")
        let guessed = try decode(#"{"id":"\#(UUID())","nameIsUserSet":false}"#)
        XCTAssertEqual(guessed.nameSource, "placeholder")
    }

    /// A source present in the file wins over the legacy flag, and the encoder
    /// no longer writes the flag at all.
    func testNameSourceRoundTripsWithoutTheLegacyFlag() throws {
        let original = PersistedSession(
            id: UUID(), name: "Wortel/Fix quiesce race", title: "shell", cwd: "/tmp",
            selected: false, nameSource: "agent", worktreeBranch: "fix/quiesce",
            gitPanelVisible: nil)
        let data = try JSONEncoder().encode([original])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nameIsUserSet"))
        let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
        XCTAssertEqual(decoded.first?.nameSource, "agent")
        XCTAssertEqual(decoded.first?.worktreeBranch, "fix/quiesce")
    }

    /// `id` is the one field with no sensible default — a record without it is
    /// unreadable, and `load()` drops the whole file rather than inventing one.
    func testMissingIDFails() {
        XCTAssertThrowsError(try decode(#"{"name":"Session 1"}"#))
    }

    // MARK: - Agent resume

    /// The agent running at quit is recorded here rather than left to the shell
    /// integration's marker file, because a clean quit destroys that marker: the
    /// agent dies first, the shell prints one last prompt on its way down, and
    /// that prompt's `precmd` deletes it before the next launch can read it.
    func testRunningAgentRoundTrips() throws {
        let session = try decode(#"""
            {"id":"\#(UUID())","runningAgent":"claude","runningModel":"opus","runningArgv":"claude --model opus"}
            """#)
        XCTAssertEqual(session.runningAgent, "claude")
        XCTAssertEqual(session.runningModel, "opus")
        XCTAssertEqual(session.runningArgv, "claude --model opus")
    }

    /// Two different "nothing to resume" cases share one representation, and that
    /// is deliberate: a file written before agent resume moved off the marker
    /// file, and a session that simply had no agent running at quit. Both must
    /// resume nothing, so neither needs distinguishing.
    func testAbsentAgentMeansNothingToResume() throws {
        let session = try decode(#"{"id":"\#(UUID())","name":"Wortel/Web"}"#)
        XCTAssertNil(session.runningAgent)
        XCTAssertNil(session.runningModel)
        XCTAssertNil(session.runningArgv)
    }

    /// The conversation a session belongs to is kept apart from whether its
    /// agent was running at quit. An agent killed from outside (a keeper
    /// force-quit) loses the running id at the next save; the last id must
    /// survive that, or a repo with two sessions resumes both into the newest
    /// transcript.
    func testLastConversationIDSurvivesTheAgentExiting() throws {
        let session = try decode(#"""
            {"id":"\#(UUID())","lastConversationID":"5131fb0c-345b-4a6c-9d49-49084d92b570"}
            """#)
        XCTAssertNil(session.runningAgent)
        XCTAssertNil(session.runningConversationID)
        XCTAssertEqual(session.lastConversationID, "5131fb0c-345b-4a6c-9d49-49084d92b570")
    }

    /// A file from before the last id existed carries the running id as both:
    /// an agent alive at quit was, by definition, the session's last conversation.
    func testRunningConversationIDSeedsTheLastOne() throws {
        let session = try decode(#"""
            {"id":"\#(UUID())","runningAgent":"claude","runningConversationID":"39027937-053d-49f7-ae3b-1eb98a87a811"}
            """#)
        XCTAssertEqual(session.lastConversationID, "39027937-053d-49f7-ae3b-1eb98a87a811")
    }

    /// An agent left on its default model records the agent and nothing else —
    /// the common case, since most agents are launched without a `--model` flag.
    func testAgentWithoutAModelIsStillResumable() throws {
        let session = try decode(#"{"id":"\#(UUID())","runningAgent":"codex"}"#)
        XCTAssertEqual(session.runningAgent, "codex")
        XCTAssertNil(session.runningModel)
    }

    // MARK: - Reading the file

    private func withTempFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir.appendingPathComponent("sessions.json"))
    }

    func testAMissingFileIsAnEmptyList() throws {
        try withTempFile { url in
            guard case .missing = SessionStore.read(url).0 else { return XCTFail("expected .missing") }
        }
    }

    func testAFileThatCannotBeReadIsNotEmpty() throws {
        try XCTSkipIf(getuid() == 0, "running as root")
        try withTempFile { url in
            try Data("[]".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            guard case .unreadable = SessionStore.read(url).0 else { return XCTFail("expected .unreadable") }
        }
    }

    func testAFileThatDoesNotDecodeIsNotEmpty() throws {
        try withTempFile { url in
            try Data("not json".utf8).write(to: url)
            guard case .unreadable = SessionStore.read(url).0 else { return XCTFail("expected .unreadable") }
        }
    }

    func testADirectoryInItsPlaceIsNotEmpty() throws {
        try withTempFile { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            guard case .unreadable = SessionStore.read(url).0 else { return XCTFail("expected .unreadable") }
        }
    }

    func testAGoodFileLoads() throws {
        try withTempFile { url in
            try Data("[]".utf8).write(to: url)
            guard case .sessions(let list) = SessionStore.read(url).0 else { return XCTFail("expected .sessions") }
            XCTAssertEqual(list.count, 0)
        }
    }

    // MARK: - Panes of the main area

    /// A split main area comes back as it was: the tree, and each pane's
    /// tabs and the one in front.
    func testASplitMainAreaRoundTrips() throws {
        let right = UUID(), under = UUID()
        let shell = SideTab.terminal(UUID())
        var layout = SplitLayout()
        layout.insert(.pane(right), beside: .main, on: .right)
        layout.insert(.pane(under), beside: .pane(right), on: .down)
        layout.moveDivider(at: [], index: 0, to: 333, in: CGRect(x: 0, y: 0, width: 801, height: 601))
        let panes = [
            right.uuidString: PersistedPaneTabs(tabs: [SideTab.pane(.changes).rawValue, shell.rawValue],
                                                active: shell.rawValue),
            under.uuidString: PersistedPaneTabs(tabs: [SideTab.file("/tmp/a:b.md").rawValue]),
        ]
        let original = PersistedSession(
            id: UUID(), name: "Wortel/App", title: "shell", cwd: "/tmp",
            selected: true, nameSource: "user", gitPanelVisible: false,
            closedTabs: [ClosedTab(tab: .pane(.files), region: .pane(right), index: 1).rawValue],
            tabHabits: [TabKind.file.rawValue: TabRegion.pane(under).rawValue],
            splitLayout: layout, paneTabs: panes)
        let data = try JSONEncoder().encode([original])
        let decoded = try XCTUnwrap(JSONDecoder().decode([PersistedSession].self, from: data).first)
        XCTAssertEqual(decoded.splitLayout, layout)
        XCTAssertEqual(decoded.paneTabs, panes)
        XCTAssertEqual(decoded.closedTabs?.compactMap(ClosedTab.init(rawValue:)),
                       [ClosedTab(tab: .pane(.files), region: .pane(right), index: 1)])
        XCTAssertEqual(decoded.tabHabits?[TabKind.file.rawValue].flatMap(TabRegion.init(rawValue:)), .pane(under))
    }

    /// A session that isn't split writes neither key: its entry is what it
    /// was before there were panes, so an older build reading it loses
    /// nothing and a newer one reads no split.
    func testAnUnsplitSessionSavesNoSplit() throws {
        let original = PersistedSession(
            id: UUID(), name: "s", title: "shell", cwd: "/tmp",
            selected: false, nameSource: "user", gitPanelVisible: false)
        let data = try JSONEncoder().encode(original)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("splitLayout"))
        XCTAssertFalse(keys.contains("paneTabs"))

        let decoded = try decode(#"{"id":"\#(UUID())"}"#)
        XCTAssertNil(decoded.splitLayout)
        XCTAssertNil(decoded.paneTabs)
    }

    /// A tree this build can't read is no split. It must not cost the
    /// session, let alone the list it is in: the pane tabs that did read are
    /// still there for `restore` to put in the main row.
    func testADamagedSplitDoesNotFailTheFile() throws {
        let pane = UUID()
        let shell = SideTab.terminal(UUID())
        let sessions = try decodeList("""
        [{"id":"\(UUID())","name":"one",
          "splitLayout":{"axis":"spiral","parts":[{"node":{"leaf":"main"},"weight":"half"}]},
          "paneTabs":{"\(pane)":{"tabs":["\(shell.rawValue)"],"active":"\(shell.rawValue)"}}},
         {"id":"\(UUID())","name":"two","splitLayout":"sideways","paneTabs":[1,2,3]},
         {"id":"\(UUID())","name":"three","splitLayout":{"leaf":"main"},
          "paneTabs":{"\(pane)":{"tabs":"none","active":7},"other":{}}}]
        """)
        XCTAssertEqual(sessions.map(\.name), ["one", "two", "three"])
        XCTAssertNil(sessions[0].splitLayout)
        XCTAssertEqual(sessions[0].paneTabs, [pane.uuidString: PersistedPaneTabs(tabs: [shell.rawValue],
                                                                              active: shell.rawValue)])
        XCTAssertNil(sessions[1].splitLayout)
        XCTAssertNil(sessions[1].paneTabs)
        XCTAssertEqual(sessions[2].splitLayout, SplitLayout())
        XCTAssertEqual(sessions[2].paneTabs, [pane.uuidString: PersistedPaneTabs(tabs: []),
                                              "other": PersistedPaneTabs(tabs: [])])
    }

    /// What `restore` makes of a pane whose tree was lost: every tab in the
    /// main row, the terminal's shell still reachable.
    func testPanesWithoutATreeFoldIntoTheMainRow() {
        let shell = SideTab.terminal(UUID())
        var tabs = WorkspaceTabs(main: [.session])
        tabs.panes[UUID()] = WorkspaceTabs.PaneTabs(tabs: [shell, .pane(.changes)], active: shell)
        let restored = tabs.normalized()
        XCTAssertEqual(restored.main, [.session, shell, .pane(.changes)])
        XCTAssertTrue(restored.panes.isEmpty)
        XCTAssertEqual(restored.terminalIDs, [shell].compactMap(\.terminalID))
    }
}
