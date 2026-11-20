import XCTest

/// A mode lost on reattach is invisible until somebody pastes, and then it is a
/// paragraph submitted one line at a time. Nothing about it throws, which is
/// why every rule here is pinned.
final class TerminalModesTests: XCTestCase {

    private func track(_ chunks: [String]) -> TerminalModes {
        var modes = TerminalModes()
        var scanner = CSIScanner()
        for chunk in chunks {
            var bytes = Array(chunk.utf8)
            bytes.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                modes.feed(base, count: raw.count, parser: &scanner)
            }
        }
        return modes
    }

    private func prelude(_ chunks: [String]) -> String {
        String(decoding: track(chunks).prelude, as: UTF8.self)
    }

    // MARK: - What has to come back

    /// The one that started this: an agent sets bracketed paste at startup, the
    /// app relaunches, and the new terminal has to be told again.
    func testBracketedPasteComesBack() {
        XCTAssertEqual(prelude(["\u{1B}[?2004h"]), "\u{1B}[?2004h")
    }

    /// A pty read ends where it ends. The real stream split `ESC[?2004` from
    /// its `h`, and a scanner that restarted per chunk would miss the sequence
    /// it exists to catch.
    func testASequenceSplitAcrossReadsIsStillSeen() {
        XCTAssertEqual(prelude(["\u{1B}[?20", "04", "h"]), "\u{1B}[?2004h")
    }

    func testOneSequenceCanSetSeveralModes() {
        let out = prelude(["\u{1B}[?1000;1002;1006h"])
        XCTAssertEqual(out, "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h")
    }

    /// Turning a mode off is state too: a program that left the alternate
    /// screen must not come back inside it.
    func testAModeTurnedOffIsRecordedAsOff() {
        XCTAssertEqual(prelude(["\u{1B}[?1049h", "\u{1B}[?1049l"]), "\u{1B}[?1049l")
    }

    /// The other half of the same bug: an agent subscribes to theme changes
    /// once, at startup, and then trusts the terminal to say when the Mac goes
    /// light or dark. A resumed terminal that never heard the subscription
    /// stays quiet, and the agent paints last night's palette forever.
    func testThemeReportsComeBack() {
        XCTAssertEqual(prelude(["\u{1B}[?2031h"]), "\u{1B}[?2031h")
        XCTAssertTrue(track(["\u{1B}[?2031h"]).wantsColorSchemeReports)
    }

    /// Whether anyone is listening is a separate question from what the prelude
    /// says, because the answer decides whether bytes may be written into the
    /// program's *input*. Nobody asked, or asked and withdrew: nothing goes in.
    func testNothingIsReportedToAProgramThatDidNotAsk() {
        XCTAssertFalse(TerminalModes().wantsColorSchemeReports)
        XCTAssertFalse(track(["\u{1B}[?2004h"]).wantsColorSchemeReports)
        XCTAssertFalse(track(["\u{1B}[?2031h", "\u{1B}[?2031l"]).wantsColorSchemeReports)
    }

    /// A Claude whose startup was never recorded (it began while nobody was
    /// attached) still gets its theme reports, paste and focus back: it is
    /// running, so it has them on, whatever the record says.
    func testARunningClaudeIsAssumedToHaveItsStartupModes() {
        let assumed = track(["\u{1B}[?1000h", "\u{1B}[?2004l"]).assuming(agent: "claude")
        XCTAssertTrue(assumed.wantsColorSchemeReports)
        XCTAssertEqual(String(decoding: assumed.prelude, as: UTF8.self),
                       "\u{1B}[?1000h\u{1B}[?1004h\u{1B}[?2004h\u{1B}[?2031h")
        // Another agent, or none: only what was recorded.
        XCTAssertFalse(TerminalModes().assuming(agent: "codex").wantsColorSchemeReports)
        XCTAssertFalse(TerminalModes().assuming(agent: nil).wantsColorSchemeReports)
    }

    /// A program that owns the whole screen and hears the change repaints
    /// itself, so it is not restarted to repaint (Claude Code fullscreen). One
    /// that printed into the scrollback cannot reach what it printed, and one
    /// that does not listen is never told: both still need a new process.
    func testOnlyAListenerOnTheAlternateScreenRepaintsItself() {
        // Claude Code fullscreen, as it starts.
        XCTAssertTrue(track(["\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?1004h", "\u{1B}[?1049h\u{1B}[?1000h"])
            .repaintsItselfOnSchemeChange)
        XCTAssertTrue(track(["\u{1B}[?1047h", "\u{1B}[?2031h"]).repaintsItselfOnSchemeChange)
        // Claude Code inline: listens, but on the main screen.
        XCTAssertFalse(track(["\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?1004h"]).repaintsItselfOnSchemeChange)
        // Left the alternate screen again.
        XCTAssertFalse(track(["\u{1B}[?2031h\u{1B}[?1049h", "\u{1B}[?1049l"]).repaintsItselfOnSchemeChange)
        // Codex: the alternate screen, no `?2031`.
        XCTAssertFalse(track(["\u{1B}[?1049h\u{1B}[?2004h"]).repaintsItselfOnSchemeChange)
        XCTAssertFalse(TerminalModes().repaintsItselfOnSchemeChange)
        // The alternate screen with no `?2031` on record: a woken terminal is
        // not told of the change, so it must not count (SessionManager reads
        // the record as it is, not `assuming(agent:)`).
        XCTAssertFalse(track(["\u{1B}[?1049h\u{1B}[?1000h"]).repaintsItselfOnSchemeChange)
    }

    /// The bytes are ghostty's own, so a catch-up report is indistinguishable
    /// from a live one — which is the point.
    func testTheColorSchemeReportIsWhatGhosttyWouldSend() {
        XCTAssertEqual(String(decoding: TerminalModes.colorSchemeReport(dark: true), as: UTF8.self),
                       "\u{1B}[?997;1n")
        XCTAssertEqual(String(decoding: TerminalModes.colorSchemeReport(dark: false), as: UTF8.self),
                       "\u{1B}[?997;2n")
    }

    func testTheKeyboardProtocolFlagsComeBack() {
        XCTAssertEqual(prelude(["\u{1B}[>1u"]), "\u{1B}[>1u")
    }

    /// A pop leaves flags this cannot know, so it claims none rather than
    /// asserting the ones it happened to see pushed.
    func testPoppingTheKeyboardProtocolClaimsNothing() {
        XCTAssertEqual(prelude(["\u{1B}[>5u", "\u{1B}[<u"]), "")
    }

    // MARK: - What must not

    /// A mode no program mentioned is the terminal's own default, and saying
    /// anything about it is noise that can only do harm.
    func testAnUntouchedModeIsNotMentioned() {
        XCTAssertEqual(prelude([]), "")
        XCTAssertEqual(prelude(["hello world\n"]), "")
    }

    /// Cursor visibility and synchronised output are toggled every frame by
    /// every TUI. Recording them would mean writing to disk continuously to
    /// restore a state that is already one frame old.
    func testPerFrameModesAreNotRecorded() {
        XCTAssertEqual(prelude(["\u{1B}[?25l\u{1B}[?2026h\u{1B}[?12h"]), "")
    }

    /// `tmux` wraps a sequence in a DCS passthrough precisely so the terminal
    /// in between does not act on it. Reading inside one records a mode this
    /// terminal was never in.
    func testASequenceInsideADCSPassthroughIsNotOurs() {
        XCTAssertEqual(prelude(["\u{1B}Ptmux;\u{1B}\u{1B}[?2004h\u{1B}\\"]), "",
                       "a passthrough is addressed to somebody else's terminal")
        // And the scanner recovers: the next real sequence still counts.
        XCTAssertEqual(prelude(["\u{1B}Ptmux;\u{1B}[?1049h\u{1B}\\", "\u{1B}[?2004h"]),
                       "\u{1B}[?2004h")
    }

    /// A title is arbitrary text, and a repository named `[?2004h` is allowed
    /// to exist.
    func testTextThatLooksLikeASequenceIsNotOne() {
        XCTAssertEqual(prelude(["\u{1B}]0;[?2004h\u{07}"]), "")
        XCTAssertEqual(prelude(["[?2004h"]), "")
    }

    /// `cat` of a binary file is a stream of bytes that keep looking like the
    /// start of a sequence. The parameter buffer must not grow with it.
    func testNoiseDoesNotAccumulate() {
        let noise = String(repeating: "\u{1B}[0123456789", count: 200)
        XCTAssertEqual(prelude([noise, "\u{1B}[?2004h"]), "\u{1B}[?2004h")
    }

    // MARK: - On disk

    func testARecordSurvivesARoundTrip() throws {
        let session = UUID()
        let modes = track(["\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?1000h\u{1B}[>1u"])
        let data = try XCTUnwrap(TerminalModeStore.encode([session: modes]))
        let back = TerminalModeStore.decode(data)
        XCTAssertEqual(back[session], modes)
        XCTAssertEqual(String(decoding: try XCTUnwrap(back[session]).prelude, as: UTF8.self),
                       "\u{1B}[?1000h\u{1B}[?1049h\u{1B}[?2004h\u{1B}[>1u")
    }

    func testASessionWithNothingRecordedIsNotStored() throws {
        let data = try XCTUnwrap(TerminalModeStore.encode([UUID(): TerminalModes()]))
        XCTAssertTrue(TerminalModeStore.decode(data).isEmpty)
    }

    func testARuinedFileRestoresNothing() {
        XCTAssertTrue(TerminalModeStore.decode(Data("not json".utf8)).isEmpty)
    }

    /// A reattach puts a running agent's startup modes into the new terminal.
    /// A hibernation later reads the record, not the assumption, so the record
    /// has to have them: without that the terminal a session woke with had no
    /// theme reports and no bracketed paste.
    func testWhatARunningAgentIsAssumedToHaveSetIsOnRecord() {
        let recorder = TerminalModeRecorder(modes: [:])
        let session = UUID()
        XCTAssertTrue(recorder.assume(agent: "claude", in: session).wantsColorSchemeReports)
        XCTAssertTrue(recorder.modes(for: session).wantsColorSchemeReports)
        XCTAssertTrue(recorder.modes(for: session).bracketedPaste)

        // What the program said itself still wins over what was assumed.
        var off = Array("\u{1B}[?2031l".utf8)
        off.withUnsafeBufferPointer { raw in
            recorder.feed(session: session, bytes: raw.baseAddress!, count: raw.count)
        }
        XCTAssertFalse(recorder.modes(for: session).wantsColorSchemeReports)

        let other = UUID()
        XCTAssertTrue(recorder.assume(agent: nil, in: other).isEmpty)
        XCTAssertTrue(recorder.assume(agent: "codex", in: other).isEmpty)
    }

    /// The recorder is what the app talks to: fed from the pty thread, read on
    /// the main thread when a surface is built.
    // MARK: - Taking back what a program switched on

    /// What Codex 0.170 switches on, as it wrote it (2026-11-19). It has no
    /// handler for any signal, so ended by one it takes none of it back.
    func testWhatAProgramSwitchedOnIsTakenBackAlternateScreenLast() {
        let modes = track(["\u{1B}[?1049h\u{1B}[?2004h\u{1B}[>5u\u{1B}[?1004h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h"])
        let undo = String(decoding: modes.undo, as: UTF8.self)
        XCTAssertEqual(undo, "\u{1B}[<u\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l\u{1B}[?1006l"
            + "\u{1B}[?2004l\u{1B}[?1049l\u{1B}[<u\u{1B}[?25h\u{1B}[?1007h")
        // And a terminal told that has nothing left on record to put back.
        let after = track([String(decoding: modes.prelude, as: UTF8.self) + undo])
        XCTAssertNil(after.keyboardFlags)
        XCTAssertFalse(after.privateModesForStorage.values.contains(true))
    }

    /// A program that tidied up after itself, or switched nothing on, is
    /// told nothing: not even the cursor.
    func testNothingOnRecordIsNothingToTakeBack() {
        XCTAssertTrue(TerminalModes().undo.isEmpty)
        XCTAssertTrue(track(["\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2004l\u{1B}[?1004l"]).undo.isEmpty)
    }

    /// `assume` writes an agent's startup modes down whether or not it set
    /// them. Once it has gone they are nobody's: left on record, every later
    /// wake put focus reporting into a plain shell's terminal and wrote a
    /// theme report at its prompt.
    func testAnAgentThatHasGoneNoLongerHasItsStartupModesOnRecord() {
        let recorder = TerminalModeRecorder(modes: [:])
        let session = UUID()
        _ = recorder.assume(agent: "claude", in: session)
        XCTAssertTrue(recorder.modes(for: session).wantsColorSchemeReports)
        recorder.forgetStartupModes(of: "claude", in: session)
        let after = recorder.modes(for: session)
        XCTAssertFalse(after.wantsColorSchemeReports)
        XCTAssertNil(after.privateModesForStorage[1004])
        XCTAssertTrue(after.bracketedPaste, "the shell at its prompt has bracketed paste on itself")
        // An agent with nothing assumed of it changes nothing.
        recorder.forgetStartupModes(of: "codex", in: session)
        XCTAssertEqual(recorder.modes(for: session), after)
    }

    func testTheRecorderKeepsEachSessionsModesApart() {
        let recorder = TerminalModeRecorder(modes: [:])
        let first = UUID(), second = UUID()
        for (session, text) in [(first, "\u{1B}[?2004h"), (second, "\u{1B}[?1049h")] {
            var bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { raw in
                recorder.feed(session: session, bytes: raw.baseAddress!, count: raw.count)
            }
        }
        XCTAssertEqual(String(decoding: recorder.modes(for: first).prelude, as: UTF8.self),
                       "\u{1B}[?2004h")
        XCTAssertEqual(String(decoding: recorder.modes(for: second).prelude, as: UTF8.self),
                       "\u{1B}[?1049h")
        recorder.forget(session: first)
        XCTAssertTrue(recorder.modes(for: first).isEmpty)
        XCTAssertFalse(recorder.modes(for: second).isEmpty)
    }
}
