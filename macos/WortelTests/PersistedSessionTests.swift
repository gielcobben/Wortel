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
                id: UUID(), name: "Wakker/Manager", title: "shell", cwd: "/tmp",
                selected: true, nameSource: "user", gitPanelVisible: visible)
            let data = try JSONEncoder().encode([original])
            let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
            XCTAssertEqual(decoded.first?.gitPanelVisible, visible)
        }
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
        {"id":"\#(UUID())","cwd":"/Users/giel/Developer/wortel/macos/Wortel/Sessions",
         "originCwd":"/Users/giel/Developer/wortel"}
        """#)
        XCTAssertEqual(session.cwd, "/Users/giel/Developer/wortel/macos/Wortel/Sessions")
        XCTAssertEqual(session.originCwd, "/Users/giel/Developer/wortel")
    }

    /// A file written before origins existed left it out, and there is nothing
    /// to recover: the origin was never recorded. It stays nil here — what an
    /// absent one falls back to is `SessionManager.restore`'s decision, and it
    /// falls back to `cwd`, the only evidence there is. That is also exactly
    /// what the old behaviour inherited, so the launch that reads an old file
    /// behaves as it always did and the drift stops from the next session on.
    func testAbsentOriginIsLeftForRestoreToResolve() throws {
        let session = try decode(#"{"id":"\#(UUID())","cwd":"/Users/giel/Developer/wortel"}"#)
        XCTAssertNil(session.originCwd, "an older file recorded no origin")
    }

    /// It has to survive a round trip, or every save would quietly downgrade
    /// every session to "no origin recorded" and the drift would come back.
    func testOriginRoundTrips() throws {
        let original = PersistedSession(
            id: UUID(), name: "Wortel/macos", title: "shell",
            cwd: "/Users/giel/Developer/wortel/macos",
            originCwd: "/Users/giel/Developer/wortel",
            selected: true, nameSource: "placeholder", gitPanelVisible: nil)
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([PersistedSession].self, from: data)
        XCTAssertEqual(decoded.first?.originCwd, "/Users/giel/Developer/wortel")
        XCTAssertEqual(decoded.first?.cwd, "/Users/giel/Developer/wortel/macos")
    }

    // MARK: - Older files

    /// A real pre-per-session file: every session decodes, and says nothing about
    /// the panel, so `SessionManager.restore` gives them all the legacy app-wide
    /// flag. The rest of the fields must survive that read untouched.
    func testPreVisibilityFileDecodes() throws {
        let sessions = try decodeList("""
        [{"id":"\(UUID())","name":"Wakker/Manager","title":"shell",
          "cwd":"/Users/giel/Developer/wakker","selected":true,"nameIsUserSet":true},
         {"id":"\(UUID())","name":"Wakker/Worker","title":"shell",
          "cwd":"/Users/giel/Developer/wortel","selected":false,"nameIsUserSet":true}]
        """)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.gitPanelVisible == nil })
        XCTAssertEqual(sessions.first?.name, "Wakker/Manager")
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

    /// An agent left on its default model records the agent and nothing else —
    /// the common case, since most agents are launched without a `--model` flag.
    func testAgentWithoutAModelIsStillResumable() throws {
        let session = try decode(#"{"id":"\#(UUID())","runningAgent":"codex"}"#)
        XCTAssertEqual(session.runningAgent, "codex")
        XCTAssertNil(session.runningModel)
    }
}
